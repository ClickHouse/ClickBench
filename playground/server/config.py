"""Central configuration for the playground server.

All knobs are read from environment variables so a single systemd unit can drop
them in. Falls back to sensible defaults for local development.

ClickHouse credentials (for the logging sink and any future shared-query
feature) can also be supplied via an INI file at
`<state_dir>/clickhouse.conf`. Env vars, if set, take precedence over the
file so existing deployments keep working unchanged.
"""
from __future__ import annotations

import configparser
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


@dataclass(frozen=True)
class Config:
    # Where on the host disk we keep VM artifacts and dataset images.
    state_dir: Path
    repo_dir: Path
    # HTTP listen target for the playground API server. Plain host:port string;
    # aiohttp parses it.
    listen_host: str
    listen_port: int
    # TLS. When tls_cert + tls_key are both set, the server binds on
    # tls_port with TLS *in addition to* listen_port (which becomes the
    # plain-HTTP redirect listener). Empty strings disable TLS.
    tls_cert: str
    tls_key: str
    tls_port: int
    # Per-VM resources.
    vm_vcpus: int
    vm_mem_mib: int
    vm_rootfs_size_gb: int
    # Watchdog thresholds.
    cpu_busy_window_sec: int
    cpu_busy_threshold: float
    # Cumulative CPU-seconds (across all vCPUs) a VM may burn between
    # restore and now. Anything past this is presumably a runaway and
    # the watchdog kicks the VM. Counts only "ready" state — provision
    # is allowed to use as much CPU as it wants.
    vm_cpu_total_seconds_cap: int
    # Seconds since the last /query a "ready" VM is allowed to linger
    # before the monitor tears it down. Snapshot is preserved; the
    # next /query restores in seconds. Keeps the kernel's KVM
    # async_pf_execute workqueue from accumulating idle VMs and
    # slowing unrelated services (sshd in particular).
    idle_kick_after_sec: int
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


def _load_clickhouse_conf(state_dir: Path) -> dict[str, str]:
    """Parse <state_dir>/clickhouse.conf. Format is INI with a single
    [clickhouse] section:

        [clickhouse]
        url = https://your-host.clickhouse.cloud:8443
        user = default
        password = ...
        db = playground

    Missing file / parse errors return {} silently — the env-var path
    still works and the logging sink just stays disabled.
    """
    path = state_dir / "clickhouse.conf"
    if not path.exists():
        return {}
    parser = configparser.ConfigParser()
    try:
        parser.read(path)
    except configparser.Error:
        return {}
    if "clickhouse" not in parser:
        return {}
    return {k: v for k, v in parser["clickhouse"].items()}


def load() -> Config:
    state_dir = Path(os.environ.get("PLAYGROUND_STATE_DIR", "/opt/clickbench-playground"))
    repo_dir = Path(os.environ.get("PLAYGROUND_REPO_DIR", "/home/ubuntu/ClickBench"))
    listen = os.environ.get("PLAYGROUND_LISTEN", "0.0.0.0:8000")
    host, _, port = listen.rpartition(":")
    ch_conf = _load_clickhouse_conf(state_dir)
    return Config(
        state_dir=state_dir,
        repo_dir=repo_dir,
        listen_host=host or "0.0.0.0",
        listen_port=int(port or 8000),
        tls_cert=os.environ.get("PLAYGROUND_TLS_CERT", ""),
        tls_key=os.environ.get("PLAYGROUND_TLS_KEY", ""),
        tls_port=_env_int("PLAYGROUND_TLS_PORT", 443),
        vm_vcpus=_env_int("VM_VCPUS", 4),
        # 16 GB. DataFrame-style engines (chdb-dataframe, duckdb-dataframe,
        # daft-*, polars-dataframe) would need >100 GB to load the full
        # hits dataset and don't fit the playground's model; they're
        # disabled in systems.py instead of bumping VM RAM for everyone.
        vm_mem_mib=_env_int("VM_MEM_MIB", 16 * 1024),
        vm_rootfs_size_gb=_env_int("VM_ROOTFS_SIZE_GB", 200),
        cpu_busy_window_sec=_env_int("VM_CPU_BUSY_WINDOW_SEC", 120),
        cpu_busy_threshold=float(os.environ.get("VM_CPU_BUSY_THRESHOLD", "0.97")),
        vm_cpu_total_seconds_cap=_env_int("VM_CPU_TOTAL_SECONDS_CAP", 3600),
        # 10 minutes default. Cold restore is ~5-30 s for most engines,
        # so a user returning within 10 min finds a warm VM; longer
        # gaps cost a single fresh restore.
        idle_kick_after_sec=_env_int("VM_IDLE_KICK_AFTER_SEC", 600),
        host_min_free_ram_gb=_env_int("HOST_MIN_FREE_RAM_GB", 32),
        host_min_free_disk_gb=_env_int("HOST_MIN_FREE_DISK_GB", 100),
        vm_disk_pct_kill_threshold=float(os.environ.get("VM_DISK_FULL_PCT", "0.97")),
        ch_cloud_url=os.environ.get("CLICKHOUSE_CLOUD_URL", ch_conf.get("url", "")),
        ch_cloud_user=os.environ.get("CLICKHOUSE_CLOUD_USER", ch_conf.get("user", "")),
        ch_cloud_password=os.environ.get("CLICKHOUSE_CLOUD_PASSWORD", ch_conf.get("password", "")),
        ch_cloud_db=os.environ.get("CLICKHOUSE_CLOUD_DB", ch_conf.get("db", "playground")),
    )
