"""Background watchdog.

Runs alongside the API server. Once per second:

  * For every running VM, sample CPU% (from /proc/<pid>/stat), RSS, and the
    rootfs file's current physical size (via stat). Update the VM record.
  * If a VM has been at >= cpu_busy_threshold for cpu_busy_window_sec
    contiguous seconds, restart it.
  * If a VM's rootfs is filled past vm_disk_pct_kill_threshold of its nominal
    cap (200 GB) — i.e. the sparse file is using more than that fraction —
    restart it.
  * Sample host free memory / free disk on the state_dir filesystem. If under
    threshold, find the largest live VM (by RSS for memory pressure, by
    rootfs_used_bytes for disk pressure) and kick it.

`kick` is implemented via vm_manager.kick(name, reason), which leaves the
snapshot intact. A subsequent /query will trigger a restore.
"""
from __future__ import annotations

import asyncio
import logging
import os
import shutil
import time
from pathlib import Path

from .config import Config
from .logging_sink import LoggingSink
from .vm_manager import VM, VMManager, _read_proc_jiffies

log = logging.getLogger("monitor")


class Monitor:
    def __init__(self, cfg: Config, vmm: VMManager, sink: LoggingSink):
        self.cfg = cfg
        self.vmm = vmm
        self.sink = sink
        self._cpu_history: dict[str, tuple[int, int, float]] = {}  # name -> (utime+stime, total, ts)
        self._task: asyncio.Task | None = None

    async def start(self) -> None:
        self._task = asyncio.create_task(self._loop(), name="monitor")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _loop(self) -> None:
        try:
            while True:
                await self._tick()
                await asyncio.sleep(1.0)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("monitor loop crashed; restarting in 5s")
            await asyncio.sleep(5)
            self._task = asyncio.create_task(self._loop(), name="monitor")

    async def _tick(self) -> None:
        # Per-VM sampling
        for name, vm in self.vmm.vms.items():
            if vm.pid is None or not _pid_alive(vm.pid):
                self._cpu_history.pop(name, None)
                vm.cpu_busy_since = None
                continue
            cpu_pct = self._sample_cpu(name, vm.pid)
            vm.rss_bytes = _rss(vm.pid)
            rootfs = self.cfg.systems_dir / name / "rootfs.ext4"
            try:
                st = rootfs.stat()
                vm.rootfs_used_bytes = st.st_blocks * 512  # actual allocated bytes
            except FileNotFoundError:
                vm.rootfs_used_bytes = 0
            await self._check_per_vm(vm, cpu_pct)

        # Host-wide checks
        await self._check_host_pressure()

    def _sample_cpu(self, name: str, pid: int) -> float | None:
        """Return ratio of CPU used since last sample, normalized by vcpu count."""
        stat_path = Path(f"/proc/{pid}/stat")
        try:
            stat = stat_path.read_text()
        except FileNotFoundError:
            self._cpu_history.pop(name, None)
            return None
        # The comm field can contain spaces — split around the last ')'
        end = stat.rfind(")")
        parts = stat[end + 2:].split()
        utime = int(parts[11])
        stime = int(parts[12])
        now = time.monotonic()
        prev = self._cpu_history.get(name)
        self._cpu_history[name] = (utime, stime, now)
        if prev is None:
            return None
        dt = now - prev[2]
        d_jiffies = (utime + stime) - (prev[0] + prev[1])
        clk = os.sysconf("SC_CLK_TCK")
        if dt <= 0 or clk <= 0:
            return None
        # Normalize by the number of vCPUs the VM was allocated.
        cpu_seconds = d_jiffies / clk
        return cpu_seconds / (dt * self.cfg.vm_vcpus)

    async def _check_per_vm(self, vm: VM, cpu_pct: float | None) -> None:
        # Idle reaper. A "ready" VM that hasn't seen a /query in
        # idle_kick_after_sec is consuming KVM threads + memory
        # mappings + a TAP for no reason. The kernel's async_pf_execute
        # workqueue starts hogging CPU when too many VMs idle-spin in
        # parallel (see dmesg), which slows down unrelated services
        # (sshd accept loop, in particular). Tear down idle ones; the
        # snapshot is preserved and the next /query restores in seconds.
        if (vm.state == "ready" and vm.last_used > 0
                and time.time() - vm.last_used >= self.cfg.idle_kick_after_sec):
            self.sink.write_event(
                system=vm.system.name, kind="idle-reaper",
                detail=f"idle for {int(time.time() - vm.last_used)}s "
                       f"(threshold {self.cfg.idle_kick_after_sec}s)",
            )
            await self.vmm.kick(vm.system.name, "idle-reaper")
            return

        # CPU saturation watchdog
        if cpu_pct is None:
            vm.cpu_busy_since = None
        elif cpu_pct >= self.cfg.cpu_busy_threshold:
            if vm.cpu_busy_since is None:
                vm.cpu_busy_since = time.monotonic()
            elif time.monotonic() - vm.cpu_busy_since > self.cfg.cpu_busy_window_sec:
                self.sink.write_event(
                    system=vm.system.name, kind="cpu-watchdog",
                    detail=f"sustained CPU >= {self.cfg.cpu_busy_threshold:.0%} for "
                           f"{self.cfg.cpu_busy_window_sec}s",
                )
                await self.vmm.kick(vm.system.name, "cpu-watchdog")
                vm.cpu_busy_since = None
                return
        else:
            vm.cpu_busy_since = None

        # Cumulative CPU-cap watchdog. Only checked once we've passed
        # the post-provision boundary (vm.state == "ready"); the
        # cpu_baseline_jiffies was captured at that transition, so the
        # delta below isolates query-serving CPU from boot/restore.
        if vm.state == "ready" and vm.pid is not None and vm.cpu_baseline_jiffies:
            jiffies = _read_proc_jiffies(vm.pid)
            if jiffies > 0:
                clk = os.sysconf("SC_CLK_TCK") or 100
                delta_s = (jiffies - vm.cpu_baseline_jiffies) / clk
                if delta_s >= self.cfg.vm_cpu_total_seconds_cap:
                    self.sink.write_event(
                        system=vm.system.name, kind="cpu-cap",
                        detail=f"cumulative CPU {delta_s:.0f}s >= "
                               f"{self.cfg.vm_cpu_total_seconds_cap}s",
                    )
                    await self.vmm.kick(vm.system.name, "cpu-cap")
                    return

        # Disk usage watchdog
        cap = self.cfg.vm_rootfs_size_gb * (1 << 30)
        if vm.rootfs_used_bytes and vm.rootfs_used_bytes / cap >= self.cfg.vm_disk_pct_kill_threshold:
            self.sink.write_event(
                system=vm.system.name, kind="disk-watchdog",
                detail=f"rootfs used {vm.rootfs_used_bytes}/{cap}",
            )
            await self.vmm.kick(vm.system.name, "disk-watchdog")

    async def _check_host_pressure(self) -> None:
        # Memory pressure
        info = _meminfo()
        free_ram_gb = info.get("MemAvailable", 0) / (1024 * 1024)  # MemAvailable is in KB
        if free_ram_gb < self.cfg.host_min_free_ram_gb:
            target = self._largest_running(by="rss")
            if target:
                self.sink.write_event(
                    system=target.system.name, kind="oom-kick",
                    detail=f"host free RAM {free_ram_gb:.1f}G < {self.cfg.host_min_free_ram_gb}G; "
                           f"largest is {target.system.name} ({target.rss_bytes/1e9:.1f}G)",
                )
                await self.vmm.kick(target.system.name, "host-mem-pressure")

        # Disk pressure on the state dir
        st = shutil.disk_usage(self.cfg.state_dir)
        free_disk_gb = st.free / (1 << 30)
        if free_disk_gb < self.cfg.host_min_free_disk_gb:
            target = self._largest_running(by="disk")
            if target:
                self.sink.write_event(
                    system=target.system.name, kind="disk-kick",
                    detail=f"host free disk {free_disk_gb:.1f}G < {self.cfg.host_min_free_disk_gb}G; "
                           f"largest is {target.system.name} ({target.rootfs_used_bytes/1e9:.1f}G)",
                )
                await self.vmm.kick(target.system.name, "host-disk-pressure")

    def _largest_running(self, *, by: str) -> VM | None:
        running = [v for v in self.vmm.vms.values()
                   if v.pid is not None and _pid_alive(v.pid)]
        if not running:
            return None
        key = (lambda v: v.rss_bytes) if by == "rss" else (lambda v: v.rootfs_used_bytes)
        return max(running, key=key)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _rss(pid: int) -> int:
    try:
        text = Path(f"/proc/{pid}/status").read_text()
    except FileNotFoundError:
        return 0
    for line in text.splitlines():
        if line.startswith("VmRSS:"):
            parts = line.split()
            return int(parts[1]) * 1024  # KB -> bytes
    return 0


def _meminfo() -> dict[str, int]:
    out: dict[str, int] = {}
    try:
        text = Path("/proc/meminfo").read_text()
    except FileNotFoundError:
        return out
    for line in text.splitlines():
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        parts = v.split()
        if parts:
            try:
                out[k.strip()] = int(parts[0])
            except ValueError:
                continue
    return out
