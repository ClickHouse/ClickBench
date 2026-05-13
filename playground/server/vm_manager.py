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
    # Keep the asyncio.subprocess.Process handle for the running firecracker.
    # Without holding it, Python eventually garbage-collects the wrapper and
    # the underlying child sits as a <defunct> zombie until the host server
    # exits — the kernel keeps the zombie's open TAP fd around with it, and a
    # subsequent restore for the same slot then fails to open the TAP with
    # "Resource busy". Holding the handle lets us `await proc.wait()` on
    # shutdown and reap immediately.
    proc: Optional[asyncio.subprocess.Process] = None
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
        # Bound the number of system-disk builds running concurrently. Each
        # build copies up to ~88 GB of dataset (for tsv/csv systems) — doing
        # 98 in parallel would thrash the host's NVMe. 6 is enough to keep
        # the disk busy without hitting writeback stalls.
        self._build_sem = asyncio.Semaphore(int(os.environ.get(
            "PLAYGROUND_BUILD_CONCURRENCY", "6")))
        # Cap on simultaneous in-flight provisions. Each one needs 4 vCPU +
        # apt-get downloads from the public internet; running 98 concurrently
        # gets rate-limited by Ubuntu mirrors and we have to retry. The host
        # has plenty of headroom for 32, which still finishes the catalog
        # in one pass.
        self._provision_sem = asyncio.Semaphore(int(os.environ.get(
            "PLAYGROUND_PROVISION_CONCURRENCY", "32")))
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
                if not _has_snapshot(vm):
                    # No snapshot (raw or compressed) yet — full provision.
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
        return f"http://{vm_ip}:50080"

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

        # Firecracker's --id accepts only [A-Za-z0-9-]; pg_* systems
        # crash with `Invalid instance ID: InvalidChar('_')` otherwise.
        fc_id = vm.system.name.replace("_", "-")
        proc = await asyncio.create_subprocess_exec(
            str(self.cfg.firecracker_bin),
            "--api-sock", str(vm.api_sock),
            "--id", fc_id,
            stdout=log_fh, stderr=log_fh, env=env, start_new_session=True,
        )
        vm.proc = proc
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
        #
        # init_on_free=1: makes the kernel zero every page as it goes back
        # on the free list. Without it, freed pages keep whatever the last
        # writer put there — and Firecracker's snapshot dumps *all* RAM,
        # so 8-12 GB of stale-but-freed daemon heap end up in snapshot.bin
        # looking random to zstd. With it on, the pre-snapshot daemon
        # shutdown leaves the guest's free pool genuinely zero-filled, and
        # zstd compresses the snapshot ~300:1. The cost is a small write
        # overhead on every free (~negligible vs the snapshot size win).
        host_ip, vm_ip, _ = net.addr_for(vm.slot)
        return (
            "console=ttyS0 reboot=k panic=1 pci=off init_on_free=1 "
            f"ip={vm_ip}::{host_ip}:255.255.255.0::eth0:off "
            "root=/dev/vda rw "
            "init=/lib/systemd/systemd "
        )

    async def _initial_provision(self, vm: VM) -> None:
        """First-time boot: build per-system images, boot with internet, run
        agent /provision, snapshot, shut down."""
        if vm.state != "down":
            raise RuntimeError(f"unexpected state for initial provision: {vm.state}")

        # Bound the heavy I/O phases:
        #   _build_images_if_needed: each call does a `cp -a /base /rootfs`
        #   that writes ~8 GB of base content. Running 98 in parallel
        #   saturates the host's NVMe writeback.
        #   _call_agent_provision: each spawn does `apt-get install`
        #   against Ubuntu mirrors and pulls 100s of MB. 98 at once gets
        #   rate-limited by the mirror.
        # Use distinct semaphores so disk and network are bounded
        # independently.
        log.info("[%s] initial provision begin", vm.system.name)
        vm.state = "provisioning"
        try:
            async with self._build_sem:
                await self._build_images_if_needed(vm)
            async with self._provision_sem:
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
        # If we're (re-)provisioning a system whose rootfs already has
        # /var/lib/clickbench-agent/provisioned set, drop just the rootfs so
        # the agent reruns the full install/start/load flow on the next
        # boot. The system.ext4 (scripts + ~14 GB of dataset) is preserved —
        # rebuilding it copies 14 GB unnecessarily.
        if rootfs.exists() and not _has_snapshot(vm):
            log.info("[%s] rootfs exists but no snapshot — dropping it for "
                     "a fresh agent state", vm.system.name)
            rootfs.unlink()
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
        try:
            await self._configure_boot(vm, restore_snapshot=restore_snapshot)
        except Exception:
            # If config fails partway, the firecracker process still owns the
            # TAP fd; without reaping it, the next attempt sees "Resource
            # busy" because the kernel hasn't released the TAP. Kill +
            # wait() before propagating.
            await self._shutdown(vm)
            raise

    async def _configure_boot(self, vm: VM, *, restore_snapshot: bool) -> None:
        sock = str(vm.api_sock)

        rootfs = self.cfg.systems_dir / vm.system.name / "rootfs.ext4"
        sysdisk = self.cfg.systems_dir / vm.system.name / "system.ext4"

        if restore_snapshot:
            # Firecracker's rule: `PUT /snapshot/load` must be the *first*
            # configuring action — no boot-source, no drives, no network
            # interfaces, no machine-config beforehand. The snapshot itself
            # encodes all of that. We just need the same TAP available on
            # the host with the same name (host_ensure_tap below handles
            # this).
            await fc.put(sock, "/snapshot/load", {
                "snapshot_path": str(vm.snapshot_state),
                "mem_backend": {"backend_type": "File", "backend_path": str(vm.snapshot_bin)},
                "enable_diff_snapshots": False,
                "resume_vm": True,
            }, timeout=120.0)
            return

        # Cold boot.
        await fc.put(sock, "/network-interfaces/eth0", {
            "iface_id": "eth0",
            "guest_mac": net.mac_for(vm.slot),
            "host_dev_name": net.tap_name(vm.slot),
        })
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
        # Shared dataset disk, attached read-only to every VM (LABEL=cbdata
        # mount in the guest fstab). Saves ~1-2 TB of host storage compared
        # to embedding the dataset into each per-system disk.
        datasets_img = self.cfg.datasets_image
        if datasets_img.exists():
            await fc.put(sock, "/drives/datasets", {
                "drive_id": "datasets",
                "path_on_host": str(datasets_img),
                "is_root_device": False,
                "is_read_only": True,
            })
        await fc.put(sock, "/machine-config", {
            "vcpu_count": self.cfg.vm_vcpus,
            "mem_size_mib": self.cfg.vm_mem_mib,
            "smt": False,
        })
        await fc.put(sock, "/actions", {"action_type": "InstanceStart"})

    async def _snapshot(self, vm: VM) -> None:
        # Flush the guest's dirty pages to the virtio-blk devices before we
        # pause the vcpus. Without an explicit sync here, KVM can freeze
        # the guest mid-flush — the snapshot then captures memory that
        # references on-disk blocks that haven't actually landed yet, and
        # the next read after restore sees a checksum mismatch / torn
        # write on whatever was being written at the moment of pause.
        await self._sync_guest(vm)

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

        # Capture the *disk* state too. The memory snapshot is meaningless on
        # its own: it has in-flight references to specific inodes / file
        # positions / mmap'd ranges on the rootfs and system disks, and if
        # those move under it the restored process malfunctions. We sparse-
        # copy the disks into a parallel "golden" path; every subsequent
        # restore boots off a fresh copy of the golden, so background work
        # the daemon does after restore (clickhouse merges, log writes,
        # /tmp churn) never persists into the next session.
        await self._snapshot_disks(vm)

        # Compress the memory dump with parallel zstd. Firecracker writes the
        # *full* 16 GB of guest memory regardless of how much was actually
        # used; zstd at -3 with -T0 turns that into ~10-12 GB in a few
        # seconds (most of the savings come from the agent's drop_caches
        # right before /snapshot — page cache zero-fills compress 50:1).
        # snapshot.state stays as-is; it's tiny (~60 KB).
        await self._compress_snapshot(vm)

    async def _compress_snapshot(self, vm: VM) -> None:
        bin_path = vm.snapshot_bin
        zst_path = vm.snapshot_bin.with_suffix(".bin.zst")
        if not bin_path.exists():
            return
        log.info("[%s] zstd -T0 -3 snapshot.bin (%s)",
                 vm.system.name, _fmt_size(bin_path.stat().st_size))
        t0 = time.monotonic()
        # Stream from snapshot.bin to .zst, multi-threaded. `--long=27`
        # widens the matching window to 128 MB which helps with repetitive
        # zero-region patterns common in guest RAM.
        proc = await asyncio.create_subprocess_exec(
            "zstd", "-T0", "-3", "--long=27", "-q", "-f",
            str(bin_path), "-o", str(zst_path),
        )
        rc = await proc.wait()
        dt = time.monotonic() - t0
        if rc != 0:
            log.warning("[%s] zstd compression failed rc=%d; keeping raw .bin",
                        vm.system.name, rc)
            zst_path.unlink(missing_ok=True)
            return
        new = zst_path.stat().st_size
        log.info("[%s] zstd done in %.1fs: %s -> %s (%.1fx)",
                 vm.system.name, dt,
                 _fmt_size(bin_path.stat().st_size), _fmt_size(new),
                 bin_path.stat().st_size / max(1, new))
        # The raw .bin can go; restore re-decompresses into a temp file.
        bin_path.unlink(missing_ok=True)

    async def _decompress_snapshot(self, vm: VM) -> None:
        """If the snapshot lives as .bin.zst, decompress to .bin in place.
        Idempotent: a no-op if .bin already exists.
        """
        bin_path = vm.snapshot_bin
        zst_path = vm.snapshot_bin.with_suffix(".bin.zst")
        if bin_path.exists():
            return
        if not zst_path.exists():
            return
        log.info("[%s] unzstd snapshot.bin.zst (%s)",
                 vm.system.name, _fmt_size(zst_path.stat().st_size))
        t0 = time.monotonic()
        proc = await asyncio.create_subprocess_exec(
            "zstd", "-T0", "-d", "-q", "-f", "--long=27",
            str(zst_path), "-o", str(bin_path),
        )
        rc = await proc.wait()
        dt = time.monotonic() - t0
        if rc != 0:
            raise RuntimeError(f"zstd decompress failed rc={rc}")
        log.info("[%s] unzstd done in %.1fs -> %s",
                 vm.system.name, dt, _fmt_size(bin_path.stat().st_size))

    async def _restore_snapshot(self, vm: VM) -> None:
        log.info("[%s] restore from snapshot", vm.system.name)
        # Always boot from a *fresh copy* of the golden disks captured at
        # snapshot time. Restore #N inherits zero state from restore #N-1,
        # which is what makes the playground safe to expose to arbitrary
        # SQL: the worst a user query can do is dirty the working copy,
        # which we throw away on the next /teardown.
        await self._restore_disks(vm)
        # If we only have the zstd-compressed memory dump, expand it before
        # Firecracker tries to mmap it.
        await self._decompress_snapshot(vm)
        await net.ensure_tap(vm.slot)
        # internet stays OFF post-snapshot
        await self._boot(vm, restore_snapshot=True)
        await self._wait_for_agent(vm, timeout=60)
        vm.state = "ready"

    def _golden_paths(self, vm: VM) -> tuple[Path, Path, Path, Path]:
        """(working rootfs, working sysdisk, golden rootfs, golden sysdisk)."""
        sys_dir = self.cfg.systems_dir / vm.system.name
        return (
            sys_dir / "rootfs.ext4",
            sys_dir / "system.ext4",
            sys_dir / "rootfs.golden.ext4",
            sys_dir / "system.golden.ext4",
        )

    async def _snapshot_disks(self, vm: VM) -> None:
        rootfs, sysdisk, rootfs_gold, sysdisk_gold = self._golden_paths(vm)
        # Atomically swap: rename the working images into the golden slot.
        # Both disks were sync'd via /sync before /snapshot/create, so
        # what's on disk is consistent with what's in the memory snapshot.
        # We'll re-create the working images by cloning from the golden
        # on every restore (see _restore_disks).
        for src, dst in ((rootfs, rootfs_gold), (sysdisk, sysdisk_gold)):
            if dst.exists():
                dst.unlink()
            os.replace(src, dst)
        log.info("[%s] golden disks saved (%s, %s)", vm.system.name,
                 _fmt_size(rootfs_gold.stat().st_size),
                 _fmt_size(sysdisk_gold.stat().st_size))

    async def _restore_disks(self, vm: VM) -> None:
        rootfs, sysdisk, rootfs_gold, sysdisk_gold = self._golden_paths(vm)
        if not rootfs_gold.exists() or not sysdisk_gold.exists():
            raise RuntimeError(
                f"[{vm.system.name}] missing golden disks; cannot restore")
        # Clone the goldens into fresh working copies. `cp --sparse=always`
        # only writes the non-zero blocks, so the cost is proportional to
        # the actual data on each disk, not its apparent 200 GB.
        for src, dst in ((rootfs_gold, rootfs), (sysdisk_gold, sysdisk)):
            if dst.exists():
                dst.unlink()
            proc = await asyncio.create_subprocess_exec(
                "cp", "--sparse=always", str(src), str(dst),
            )
            rc = await proc.wait()
            if rc != 0:
                raise RuntimeError(f"cp {src} -> {dst} failed rc={rc}")
        log.info("[%s] working disks cloned from golden", vm.system.name)

    async def _shutdown(self, vm: VM) -> None:
        """Best-effort clean shutdown of the firecracker process.

        Always reap the asyncio.subprocess.Process handle so the kernel
        releases its open file descriptors (notably the TAP — without this
        the next /restore for the same slot fails with `Resource busy`).
        """
        if not vm.pid and not vm.proc:
            return
        with contextlib.suppress(Exception):
            await fc.put(str(vm.api_sock), "/actions", {"action_type": "SendCtrlAltDel"})
        # Wait briefly for graceful exit.
        for _ in range(50):
            if vm.pid is None or not _pid_alive(vm.pid):
                break
            await asyncio.sleep(0.1)
        if vm.pid is not None and _pid_alive(vm.pid):
            with contextlib.suppress(ProcessLookupError):
                os.kill(vm.pid, signal.SIGKILL)
        # Reap the process. asyncio.Process.wait() drains the exit status so
        # the kernel can release the resources (TAP fd, memory mappings).
        if vm.proc is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(vm.proc.wait(), timeout=5.0)
        vm.proc = None
        vm.pid = None
        with contextlib.suppress(FileNotFoundError):
            vm.api_sock.unlink()

    async def _teardown(self, vm: VM, reason: str) -> None:
        log.warning("[%s] teardown: %s", vm.system.name, reason)
        with contextlib.suppress(Exception):
            await self._shutdown(vm)
        vm.state = "snapshotted" if _has_snapshot(vm) else "down"
        # Drop the decompressed snapshot.bin if we still have the .zst — it's
        # ~16 GB of redundancy on disk. Keep .zst as the canonical artifact.
        zst = vm.snapshot_bin.with_suffix(".bin.zst")
        if vm.snapshot_bin.exists() and zst.exists():
            with contextlib.suppress(FileNotFoundError):
                vm.snapshot_bin.unlink()
        # Discard the working disks. Any changes the daemon scribbled into
        # them during this session (background merges, log writes, /tmp
        # churn) die with them; the next restore will clone fresh copies
        # from the golden disks, so user N+1 sees the same starting state
        # as user N.
        if _has_snapshot(vm):
            rootfs, sysdisk, _, _ = self._golden_paths(vm)
            for p in (rootfs, sysdisk):
                with contextlib.suppress(FileNotFoundError):
                    p.unlink()

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

    async def _sync_guest(self, vm: VM) -> None:
        url = self.agent_url(vm) + "/sync"
        try:
            async with aiohttp.ClientSession() as s:
                async with s.post(url, timeout=aiohttp.ClientTimeout(total=300)) as r:
                    body = (await r.read()).decode("utf-8", errors="replace").strip()
                    log.info("[%s] guest sync: %s", vm.system.name, body)
        except Exception as e:
            log.warning("[%s] guest sync failed (%r); proceeding anyway", vm.system.name, e)


def _has_snapshot(vm: VM) -> bool:
    """A snapshot is complete only when *both* the memory image and the
    golden disks have been captured. A half-built snapshot (memory present
    but goldens missing, or vice versa) is treated as no snapshot at all
    so the next ensure_ready_for_query re-provisions cleanly.
    """
    mem_ok = (vm.snapshot_bin.exists() or
              vm.snapshot_bin.with_suffix(".bin.zst").exists())
    sys_dir = vm.snapshot_bin.parent
    disks_ok = ((sys_dir / "rootfs.golden.ext4").exists() and
                (sys_dir / "system.golden.ext4").exists())
    return mem_ok and disks_ok


def _fmt_size(n: int) -> str:
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024:
            return f"{n:.1f}{u}"
        n //= 1024
    return f"{n}PiB"


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
