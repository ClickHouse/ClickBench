"""Per-system Firecracker microVM lifecycle.

For each ClickBench system we manage a VM with this lifecycle:

    [DOWN] --build_images--> [DOWN(images-ready)]
        --first_boot--> [PROVISIONING] (internet ON, /provision called)
        --snapshot--> [SNAPSHOTTED(internet OFF)]
        --restore--> [READY] (handles /query requests)
        --idle / OOM / disk full / forced--> kill -> [SNAPSHOTTED]

State transitions are gated by `VM.lock`. The public API
`ensure_ready_for_query(system)` returns an `(agent_url, vm)` ready to take a
POST /query, doing whatever transitions are needed.

We avoid the jailer for now: the playground host already runs as a dedicated
user; the chroot/cgroups layer would complicate dataset disk attach and
the value-add over a vanilla firecracker process is small for our threat
model (untrusted SQL but cooperatively-built rootfs).
"""
from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import json
import logging
import os
import shutil
import signal
import time
from pathlib import Path
from typing import Optional

import aiohttp

from . import firecracker as fc
from . import net
from .config import Config
from .systems import System

log = logging.getLogger("vm_manager")


# Lifecycle states for VM.state:
#   "down"          no firecracker process for this system
#   "provisioning"  firecracker is up, install/start/load running inside
#   "ready"         firecracker is up, snapshotted at least once, /query OK
#   "snapshotted"   firecracker process is down, but snapshot.bin exists
@dataclasses.dataclass
class VM:
    system: System
    slot: int
    # Firecracker config
    api_sock: Path
    log_sock: Path  # we just point this at /dev/null actually
    pid: Optional[int] = None
    state: str = "down"
    # Snapshot artifacts
    snapshot_bin: Path = dataclasses.field(default_factory=lambda: Path())
    snapshot_state: Path = dataclasses.field(default_factory=lambda: Path())
    # Provision metadata
    provisioned_at: Optional[float] = None
    last_used: float = 0.0
    last_error: Optional[str] = None
    lock: asyncio.Lock = dataclasses.field(default_factory=asyncio.Lock)
    # Runtime stats refreshed by the monitor
    cpu_busy_since: Optional[float] = None
    rss_bytes: int = 0
    rootfs_used_bytes: int = 0


class VMManager:
    """Owns the registry of per-system VMs."""

    def __init__(self, config: Config, systems: dict[str, System]):
        self.cfg = config
        self.systems = systems
        self.vms: dict[str, VM] = {}
        # Stable slot allocation: sort systems alphabetically so each system
        # always gets the same slot id (and therefore the same TAP/IP).
        for i, name in enumerate(sorted(systems.keys()), start=1):
            sys = systems[name]
            sys_state_dir = config.systems_dir / name
            sys_state_dir.mkdir(parents=True, exist_ok=True)
            self.vms[name] = VM(
                system=sys,
                slot=i,
                api_sock=config.vms_dir / f"{name}.sock",
                log_sock=config.vms_dir / f"{name}.log.sock",
                snapshot_bin=sys_state_dir / "snapshot.bin",
                snapshot_state=sys_state_dir / "snapshot.state",
            )

    # ── public API ───────────────────────────────────────────────────────

    async def ensure_ready_for_query(self, system: str) -> VM:
        """Make sure system is up and responsive to /query. Boot/resume as needed.

        On success the returned VM is in state "ready" and self.last_used has
        been touched.
        """
        if system not in self.vms:
            raise KeyError(system)
        vm = self.vms[system]
        async with vm.lock:
            if vm.state == "ready" and vm.pid and await self._agent_healthy(vm):
                vm.last_used = time.time()
                return vm
            # The state machine: drive to "ready" by the cheapest available path.
            if vm.state == "ready":
                # Process is gone or unresponsive. Treat as snapshotted.
                vm.state = "snapshotted"
            if vm.state == "down":
                if not vm.snapshot_bin.exists():
                    # No snapshot yet — need a full provision.
                    await self._initial_provision(vm)
                else:
                    await self._restore_snapshot(vm)
            elif vm.state == "snapshotted":
                await self._restore_snapshot(vm)
            elif vm.state == "provisioning":
                raise RuntimeError(f"{system}: provisioning in progress")
            vm.last_used = time.time()
            return vm

    async def kick(self, system: str, reason: str) -> None:
        """Forcibly tear down the VM. Caller (monitor) is responsible for logging."""
        vm = self.vms.get(system)
        if vm is None:
            return
        async with vm.lock:
            await self._teardown(vm, reason)

    def list_all(self) -> list[dict]:
        out = []
        for name, vm in self.vms.items():
            out.append({
                "name": name,
                "system": vm.system.display_name,
                "state": vm.state,
                "slot": vm.slot,
                "agent_url": self.agent_url(vm),
                "provisioned_at": vm.provisioned_at,
                "last_used": vm.last_used,
                "tags": list(vm.system.tags),
                "data_format": vm.system.data_format,
                "last_error": vm.last_error,
                "rss_bytes": vm.rss_bytes,
                "rootfs_used_bytes": vm.rootfs_used_bytes,
                "has_snapshot": vm.snapshot_bin.exists(),
            })
        return out

    def agent_url(self, vm: VM) -> str:
        _, vm_ip, _ = net.addr_for(vm.slot)
        return f"http://{vm_ip}:8080"

    # ── boot / shutdown ──────────────────────────────────────────────────

    async def _spawn_firecracker(self, vm: VM) -> None:
        """Start a fresh firecracker process listening on vm.api_sock."""
        with contextlib.suppress(FileNotFoundError):
            vm.api_sock.unlink()
        vm.api_sock.parent.mkdir(parents=True, exist_ok=True)

        env = os.environ.copy()
        env["RUST_BACKTRACE"] = "1"

        log_path = self.cfg.logs_dir / f"firecracker-{vm.system.name}.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        # Append to the existing log so prior runs are kept for postmortems.
        log_fh = open(log_path, "ab", buffering=0)

        proc = await asyncio.create_subprocess_exec(
            str(self.cfg.firecracker_bin),
            "--api-sock", str(vm.api_sock),
            "--id", vm.system.name,
            stdout=log_fh, stderr=log_fh, env=env, start_new_session=True,
        )
        vm.pid = proc.pid
        # Wait for the API socket to exist
        for _ in range(80):
            if vm.api_sock.exists():
                break
            await asyncio.sleep(0.05)
        if not vm.api_sock.exists():
            raise RuntimeError("firecracker did not create API socket in time")

    def _kernel_cmdline(self, vm: VM) -> str:
        # console=ttyS0 so we get a serial-attached login (in case we drop a
        # console socket for debugging); reboot=k for clean halt-on-panic.
        # The kernel's built-in IP autoconfig statically assigns the VM's
        # /24 from its slot, sidestepping any DHCP/networkd in userland.
        host_ip, vm_ip, _ = net.addr_for(vm.slot)
        return (
            "console=ttyS0 reboot=k panic=1 pci=off "
            f"ip={vm_ip}::{host_ip}:255.255.255.0::eth0:off "
            "root=/dev/vda rw "
            "init=/lib/systemd/systemd "
        )

    async def _initial_provision(self, vm: VM) -> None:
        """First-time boot: build per-system images, boot with internet, run
        agent /provision, snapshot, shut down."""
        if vm.state != "down":
            raise RuntimeError(f"unexpected state for initial provision: {vm.state}")

        log.info("[%s] initial provision begin", vm.system.name)
        vm.state = "provisioning"
        try:
            await self._build_images_if_needed(vm)
            await net.ensure_tap(vm.slot)
            await net.enable_internet(vm.slot)
            await self._boot(vm, restore_snapshot=False)
            await self._wait_for_agent(vm, timeout=180)
            await self._call_agent_provision(vm)
            await self._snapshot(vm)
            await self._shutdown(vm)
            await net.disable_internet(vm.slot)
            vm.state = "snapshotted"
            vm.provisioned_at = time.time()
            log.info("[%s] initial provision complete", vm.system.name)
        except Exception as e:
            vm.last_error = f"provision: {e!r}"
            log.exception("[%s] provision failed", vm.system.name)
            await self._teardown(vm, "provision-failed")
            raise

    async def _build_images_if_needed(self, vm: VM) -> None:
        sys_dir = self.cfg.systems_dir / vm.system.name
        rootfs = sys_dir / "rootfs.ext4"
        sysdisk = sys_dir / "system.ext4"
        if rootfs.exists() and sysdisk.exists():
            return
        log.info("[%s] building rootfs + system disk", vm.system.name)
        script = self.cfg.repo_dir / "playground" / "images" / "build-system-rootfs.sh"
        p = await asyncio.create_subprocess_exec(
            "bash", str(script), vm.system.name,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
            env={**os.environ, "PLAYGROUND_STATE_DIR": str(self.cfg.state_dir)},
        )
        out, _ = await p.communicate()
        if p.returncode != 0:
            raise RuntimeError(f"build-system-rootfs failed: {out.decode(errors='replace')[-2000:]}")

    async def _boot(self, vm: VM, *, restore_snapshot: bool) -> None:
        """Configure and start a Firecracker instance. If restore_snapshot is
        True, we load from the snapshot files; else we cold-boot from kernel +
        rootfs."""
        await self._spawn_firecracker(vm)
        sock = str(vm.api_sock)

        # Network: must be configured *before* either boot path.
        await fc.put(sock, f"/network-interfaces/eth0", {
            "iface_id": "eth0",
            "guest_mac": net.mac_for(vm.slot),
            "host_dev_name": net.tap_name(vm.slot),
        })

        rootfs = self.cfg.systems_dir / vm.system.name / "rootfs.ext4"
        sysdisk = self.cfg.systems_dir / vm.system.name / "system.ext4"

        if restore_snapshot:
            # Drives must match the layout that existed when the snapshot was
            # taken, but Firecracker re-reads file paths on restore. We rebind
            # them here in case the absolute paths changed (e.g. snapshot moved).
            await fc.put(sock, "/snapshot/load", {
                "snapshot_path": str(vm.snapshot_state),
                "mem_backend": {"backend_type": "File", "backend_path": str(vm.snapshot_bin)},
                "enable_diff_snapshots": False,
                "resume_vm": True,
            })
            return

        # Cold boot.
        await fc.put(sock, "/boot-source", {
            "kernel_image_path": str(self.cfg.kernel_path),
            "boot_args": self._kernel_cmdline(vm),
        })
        await fc.put(sock, "/drives/rootfs", {
            "drive_id": "rootfs",
            "path_on_host": str(rootfs),
            "is_root_device": True,
            "is_read_only": False,
        })
        await fc.put(sock, "/drives/system", {
            "drive_id": "system",
            "path_on_host": str(sysdisk),
            "is_root_device": False,
            "is_read_only": False,
        })
        await fc.put(sock, "/machine-config", {
            "vcpu_count": self.cfg.vm_vcpus,
            "mem_size_mib": self.cfg.vm_mem_mib,
            "smt": False,
        })
        await fc.put(sock, "/actions", {"action_type": "InstanceStart"})

    async def _snapshot(self, vm: VM) -> None:
        sock = str(vm.api_sock)
        await fc.patch(sock, "/vm", {"state": "Paused"})
        try:
            await fc.put(sock, "/snapshot/create", {
                "snapshot_type": "Full",
                "snapshot_path": str(vm.snapshot_state),
                "mem_file_path": str(vm.snapshot_bin),
            }, timeout=600.0)
        finally:
            # Try to resume so we can shut down cleanly; ignore failures.
            with contextlib.suppress(Exception):
                await fc.patch(sock, "/vm", {"state": "Resumed"})

    async def _restore_snapshot(self, vm: VM) -> None:
        log.info("[%s] restore from snapshot", vm.system.name)
        await net.ensure_tap(vm.slot)
        # internet stays OFF post-snapshot
        await self._boot(vm, restore_snapshot=True)
        await self._wait_for_agent(vm, timeout=60)
        vm.state = "ready"

    async def _shutdown(self, vm: VM) -> None:
        """Best-effort clean shutdown of the firecracker process."""
        if not vm.pid:
            return
        with contextlib.suppress(Exception):
            await fc.put(str(vm.api_sock), "/actions", {"action_type": "SendCtrlAltDel"})
        # Wait briefly for graceful exit
        for _ in range(50):
            if not _pid_alive(vm.pid):
                break
            await asyncio.sleep(0.1)
        if _pid_alive(vm.pid):
            with contextlib.suppress(ProcessLookupError):
                os.kill(vm.pid, signal.SIGKILL)
        vm.pid = None
        with contextlib.suppress(FileNotFoundError):
            vm.api_sock.unlink()

    async def _teardown(self, vm: VM, reason: str) -> None:
        log.warning("[%s] teardown: %s", vm.system.name, reason)
        with contextlib.suppress(Exception):
            await self._shutdown(vm)
        vm.state = "snapshotted" if vm.snapshot_bin.exists() else "down"

    # ── agent helpers ────────────────────────────────────────────────────

    async def _agent_healthy(self, vm: VM) -> bool:
        if not vm.pid or not _pid_alive(vm.pid):
            return False
        url = self.agent_url(vm) + "/health"
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(url, timeout=aiohttp.ClientTimeout(total=2)) as r:
                    return r.status == 200
        except Exception:
            return False

    async def _wait_for_agent(self, vm: VM, *, timeout: float) -> None:
        url = self.agent_url(vm) + "/health"
        t0 = time.monotonic()
        last_err: Exception | None = None
        async with aiohttp.ClientSession() as s:
            while time.monotonic() - t0 < timeout:
                try:
                    async with s.get(url, timeout=aiohttp.ClientTimeout(total=2)) as r:
                        if r.status == 200:
                            return
                except Exception as e:
                    last_err = e
                await asyncio.sleep(0.5)
        raise RuntimeError(f"agent unreachable after {timeout}s: {last_err!r}")

    async def _call_agent_provision(self, vm: VM) -> None:
        url = self.agent_url(vm) + "/provision"
        async with aiohttp.ClientSession() as s:
            # Provision can take a very long time (apt-get install jdk, etc.)
            async with s.post(url, timeout=aiohttp.ClientTimeout(total=7200)) as r:
                body = await r.read()
                if r.status >= 300:
                    raise RuntimeError(f"agent /provision failed: {r.status}: "
                                       f"{body[-2000:].decode(errors='replace')}")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
