"""Central configuration for the playground server.

All knobs are read from environment variables so a single systemd unit can drop
them in. Falls back to sensible defaults for local development.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _env_int(name: str, default: int) -> int:
    v = os.environ.get(name)
    if not v:
        return default
    try:
        return int(v)
    except ValueError:
        return default


def _env_bytes(name: str, default: int) -> int:
    return _env_int(name, default)


@dataclass(frozen=True)
class Config:
    # Where on the host disk we keep VM artifacts and dataset images.
    state_dir: Path
    repo_dir: Path
    # HTTP listen target for the playground API server. Plain host:port string;
    # aiohttp parses it.
    listen_host: str
    listen_port: int
    # Per-VM resources.
    vm_vcpus: int
    vm_mem_mib: int
    vm_rootfs_size_gb: int
    # Output cap applied at the host edge (the agent enforces a per-VM cap too).
    output_limit_bytes: int
    # Max number of VMs we'll keep "warm" (resumed from snapshot, ready to
    # answer) concurrently.
    max_warm_vms: int
    # Watchdog thresholds.
    cpu_busy_window_sec: int
    cpu_busy_threshold: float
    host_min_free_ram_gb: int
    host_min_free_disk_gb: int
    # Per-system disk full check.
    vm_disk_pct_kill_threshold: float
    # ClickHouse Cloud logging.
    ch_cloud_url: str
    ch_cloud_user: str
    ch_cloud_password: str
    ch_cloud_db: str

    @property
    def kernel_path(self) -> Path: return self.state_dir / "kernel" / "vmlinux"
    @property
    def base_rootfs(self) -> Path: return self.state_dir / "base-rootfs.ext4"
    @property
    def datasets_image(self) -> Path: return self.state_dir / "datasets.ext4"
    @property
    def systems_dir(self) -> Path: return self.state_dir / "systems"
    @property
    def vms_dir(self) -> Path: return self.state_dir / "vms"
    @property
    def logs_dir(self) -> Path: return self.state_dir / "logs"
    @property
    def firecracker_bin(self) -> Path: return self.state_dir / "bin" / "firecracker"


def load() -> Config:
    state_dir = Path(os.environ.get("PLAYGROUND_STATE_DIR", "/opt/clickbench-playground"))
    repo_dir = Path(os.environ.get("PLAYGROUND_REPO_DIR", "/home/ubuntu/ClickBench"))
    listen = os.environ.get("PLAYGROUND_LISTEN", "0.0.0.0:8000")
    host, _, port = listen.rpartition(":")
    return Config(
        state_dir=state_dir,
        repo_dir=repo_dir,
        listen_host=host or "0.0.0.0",
        listen_port=int(port or 8000),
        vm_vcpus=_env_int("VM_VCPUS", 4),
        vm_mem_mib=_env_int("VM_MEM_MIB", 16 * 1024),
        vm_rootfs_size_gb=_env_int("VM_ROOTFS_SIZE_GB", 200),
        output_limit_bytes=_env_bytes("PLAYGROUND_OUTPUT_LIMIT", 10 * 1024),
        max_warm_vms=_env_int("PLAYGROUND_MAX_VMS", 16),
        cpu_busy_window_sec=_env_int("VM_CPU_BUSY_WINDOW_SEC", 120),
        cpu_busy_threshold=float(os.environ.get("VM_CPU_BUSY_THRESHOLD", "0.97")),
        host_min_free_ram_gb=_env_int("HOST_MIN_FREE_RAM_GB", 32),
        host_min_free_disk_gb=_env_int("HOST_MIN_FREE_DISK_GB", 500),
        vm_disk_pct_kill_threshold=float(os.environ.get("VM_DISK_FULL_PCT", "0.97")),
        ch_cloud_url=os.environ.get("CLICKHOUSE_CLOUD_URL", ""),
        ch_cloud_user=os.environ.get("CLICKHOUSE_CLOUD_USER", ""),
        ch_cloud_password=os.environ.get("CLICKHOUSE_CLOUD_PASSWORD", ""),
        ch_cloud_db=os.environ.get("CLICKHOUSE_CLOUD_DB", "playground"),
    )
