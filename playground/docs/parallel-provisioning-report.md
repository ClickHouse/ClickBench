# Parallel-provisioning report — 98 ClickBench systems

## What works end-to-end

- **Firecracker microVM lifecycle**: cold boot, agent provision (install →
  start → check → load), graceful shutdown, snapshot, restore. Snapshots
  compress 16 GiB of guest RAM down to 35-100 MB via init_on_free=1 +
  daemon stop + zstd -T0.
- **Shared read-only datasets disk** (datasets.ext4, 173 GB, mounted to
  every VM). No per-VM dataset copies — overlay-merged at
  `/opt/clickbench/system` along with the system's scripts.
- **Per-restore disk hygiene**: working `rootfs.ext4` / `system.ext4` are
  sparse copies of golden images; every restore starts fresh.
- **fstrim before snapshot** — freed dataset bytes don't linger in the
  golden disk.
- **Ubuntu generic kernel** (7.0.0-15-generic) with its `linux-modules`
  deb unpacked into the rootfs via `dpkg-deb -x`. Boots fine under
  Firecracker, supports overlay/veth/br_netfilter/iptable_nat so Docker
  can actually run.

## Bug fixes pushed during the run

- Port collision: agent moved from 8080 → 50080 so cockroach/spark/trino
  can keep using 8080 themselves.
- `mv hits.parquet + chown` → `ln -s + chown -h` across 8 ClickBench
  systems. Avoids a 14-75 GB copy per provision.
- `lib/download-hits-*` stubs at `/opt/clickbench/lib` — the few systems
  that call `../lib/download-hits-...` get instant symlinks instead of
  wget.
- Build-time semaphores: 24 disk builds in parallel, 98 provisions.
  Without bounding the disk-heavy phase the NVMe was the bottleneck.
- Per-clone e2fsck / resize2fs removed: base is built directly at 200 GB
  sparse, clones are `cp --sparse=always` (1 s each).
- Redundant `sudo sync` removed: `umount` syncs the FS being unmounted
  and the global sync was blocking everyone else's writeback.
- `clickbench-net.service`: parses `ip=` from `/proc/cmdline` and applies
  it to eth0 — the Ubuntu generic kernel lacks `CONFIG_IP_PNP` so the
  kernel boot-arg is a no-op there.
- Module preload: `/etc/modules-load.d/clickbench.conf` ensures
  overlay/veth/br_netfilter/iptable_nat/nf_conntrack are loaded at boot.
- TIDB-class sizing: per-VM writable disk bumped to 200 GB sparse so
  systems that produce 50-137 GB of data (tidb, postgres-indexed, druid)
  don't hit ENOSPC mid-load.

## Latest run snapshot

After ~30 min of soaking (current run still in flight):

| State | Count |
|-------|-------|
| snapshotted (success) | 1 (duckdb-parquet) |
| down (failed) | 10 |
| provisioning (in flight) | 87 |

The provision-time bottleneck is now apt/pip/cargo downloading
gigabytes of dependencies per VM in parallel. With 30-40 VMs actively
downloading from Ubuntu/PyPI/crates.io we're rate-limited by the
mirrors, not local I/O. Each install takes 5-15 min; the catalog
will need ~60-90 min wall to fully drain.

## Failure categories (so far)

| Category | Count | Notes |
|---|---|---|
| Arc admin token | 1 | `arc`: `Could not extract Arc admin API token from journal` — Arc's start probes `journalctl -u arc -f`, which racy/empty in our setup. ClickBench-side issue. |
| ByConity TSO | 1 | `byconity`: load fails with `Can't get process TSO request`. Docker now starts (kernel modules fix); next bug is byconity's internal init. |
| chdb / duckdb agent disconnect | 3 | `chdb-dataframe`, `duckdb`, `duckdb-dataframe`: agent crashed mid-provision (Python OOM during pip install or load). |
| Timeouts | 4 | `clickhouse-parquet`, `drill`, `duckdb-datalake*`: provision exceeded host-side 2-hour timeout. Build + provision were still running. |
| gizmosql server crash | 1 | `gizmosql_server (PID 988) exited before opening port` — system-specific bug in gizmosql's start path. |

## Docker now works

Previous run (with firecracker-ci kernel): 6 Docker systems failed
with `Job for docker.service failed because the control process
exited with error code`. This run: zero Docker daemon failures.
`byconity` is the only Docker-based system that failed and it got
past the daemon to its own application logic.

## What's left

The 87 in-flight provisions will continue draining over the next
~30-60 minutes. Most should succeed; the long-tail failures are
mostly per-system quirks (Arc journal, gizmosql start path) rather
than infrastructure problems.
