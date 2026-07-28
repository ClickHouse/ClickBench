# ClickBench Playground — Installation

End-to-end setup for a fresh Ubuntu 24.04 host. Everything lives under
`/opt/clickbench-playground/` once it's running. Total disk: ~7 TB at full
catalog (100 systems × multi-GB-per-system goldens, on btrfs with zstd
compression).

## 0. Host prerequisites

- Ubuntu 24.04 (noble), x86_64
- `/dev/kvm` accessible (bare metal or a virt-enabled cloud instance —
  `c6a.metal`, `m7i.metal-24xl`, `i4i.metal`, etc.)
- A dedicated block device for the playground state directory, plus
  enough free space for ~7 TB of system goldens and ~200 GB of datasets.
- Outbound internet at install time (apt mirrors, GitHub releases,
  Docker Hub, dataset downloads).
- Python 3.12+ on the host.

## 1. Format the state volume (btrfs + transparent zstd)

The playground depends on **reflink** (instant per-VM disk cloning) and
**transparent compression** (snapshots otherwise wouldn't fit). Btrfs gives
both. XFS works for reflink but lacks compression and fills the host at
~7 TB once all systems are provisioned.

```
sudo mkfs.btrfs -L cbplayground -f /dev/<your-device>
echo 'LABEL=cbplayground /opt/clickbench-playground btrfs \
    defaults,noatime,compress-force=zstd:6,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /opt/clickbench-playground
sudo mount /opt/clickbench-playground
```

Notes on the mount options:

- `compress-force` (not `compress`): btrfs' default heuristic samples the
  first 128 KiB of each file and skips compression when that head looks
  incompressible. For the ext4 disk images we write the sparse-metadata
  head throws the sampler off, and roughly 80 % of the data ends up
  stored raw. `compress-force` disables the heuristic and compresses
  everything.
- `zstd:6` (not `zstd:1`): the ratio delta on the compressible portion
  is modest (~10 %), but it adds up over 6+ TiB of goldens. Compression
  speed drops from ~500 MB/s to ~120 MB/s per core — writeback stays
  disk-bound anyway, and the CPU is idle during provisioning.

If you're upgrading an existing playground volume from `compress=zstd:1`,
remount with the new options and then re-encode existing extents:

```
sudo mount -o remount,compress-force=zstd:6 /opt/clickbench-playground
sudo btrfs filesystem defragment -r -f -czstd -t 128M \
    /opt/clickbench-playground/systems
```

The defrag pass is heavy (rewrites all extents; 20 h–3 days for a 7 TiB
volume) and briefly increases disk usage while old extents remain
reflink-referenced by golden files. Run it under `ionice -c 3 nice -n 15`
if the playground is serving live traffic.

## 2. Clone the repo

```
sudo apt-get update
sudo apt-get install -y git python3 python3-pip
cd /home/ubuntu
git clone https://github.com/ClickHouse/ClickBench
cd ClickBench
pip3 install --user -r playground/requirements.txt
```

## 3. Sudoers entry for the server

The playground server runs as the unprivileged `ubuntu` user but needs to
call `sudo ip ...`, `sudo iptables ...`, `sudo mount`, `sudo cp`, `sudo
firecracker`, etc. Add a sudoers fragment so those calls don't prompt:

```
sudo tee /etc/sudoers.d/clickbench-playground >/dev/null <<'EOF'
ubuntu ALL=(root) NOPASSWD: /usr/sbin/ip, /usr/sbin/iptables, \
    /usr/bin/mount, /usr/bin/umount, /usr/bin/cp, /usr/bin/mv, \
    /usr/bin/chown, /usr/bin/chmod, /usr/bin/mkdir, /usr/bin/rm, \
    /usr/bin/dd, /usr/bin/truncate, /usr/sbin/mkfs.ext4, \
    /usr/sbin/losetup, /opt/clickbench-playground/bin/firecracker, \
    /opt/clickbench-playground/bin/jailer
EOF
sudo chmod 440 /etc/sudoers.d/clickbench-playground
```

Tighten the allowlist further if your security model demands it.

## 4. Install Firecracker, kernel, host firewall, DNS, (optional) TLS

```
sudo playground/scripts/install-firecracker.sh
```

This script is idempotent. It:

- Downloads `firecracker` + `jailer` (v1.13.1) into
  `/opt/clickbench-playground/bin/`.
- Downloads the guest kernel (`vmlinux-6.1.141` from firecracker-ci) into
  `/opt/clickbench-playground/kernel/vmlinux`.
- Sets `net.ipv4.conf.all.route_localnet=1` (needed by the SNI proxy
  REDIRECT path).
- Installs `dnsmasq` and configures it as a UDP-only resolver on port 53
  for the per-VM TAPs.
- Sanity-checks that the state dir actually supports reflink.

To enable TLS for the public API at the same time, set the domain first:

```
export PLAYGROUND_TLS_DOMAIN=clickbench-playground.example.com
export PLAYGROUND_TLS_EMAIL=ops@example.com   # optional, defaults to ubuntu@$(hostname -d)
sudo -E playground/scripts/install-firecracker.sh
```

This invokes `certbot --standalone` to issue a cert, configures a deploy
hook so the `ssl-cert` group can read the renewed privkey, and adds the
operator user to the `ssl-cert` group.

## 5. Download the datasets (~200 GB, slow)

```
playground/scripts/download-datasets.sh
```

Populates `/opt/clickbench-playground/datasets/` with:

- `hits.parquet` — single-file parquet (~14 GB)
- `hits_partitioned/hits_0..99.parquet` — partitioned parquet
- `hits.tsv` — decompressed TSV (~75 GB)
- `hits.csv` — decompressed CSV (~75 GB)
- `hits.json` / `hits.json.gz` — JSON variants for parseable /
  victorialogs

The script uses `wget --continue` per format, so re-running picks up
where it left off.

## 6. Build the read-only dataset image

```
playground/images/build-datasets-image.sh
```

rsyncs the `datasets/` directory into `datasets.ext4`, sized to fit, with
no journal and zero reserved blocks. This image is attached read-only to
every VM as `LABEL=cbdata`.

## 7. Build the base rootfs

```
sudo playground/images/build-base-rootfs.sh
```

Starts from the official Ubuntu 24.04 cloud image and adds:

- The in-VM agent at `/opt/clickbench-agent/agent.py` plus its systemd
  unit.
- Forced iptables-legacy alternatives (Docker on the Firecracker kernel
  needs them — `nf_tables` isn't compiled in).
- `/etc/docker/daemon.json` with `"iptables": false`, so Docker doesn't
  try to manage the (missing) `raw` table.
- A preloaded kernel-module list (`overlay`, `br_netfilter`, `veth`,
  `ip_tables`, `iptable_*`, `nf_conntrack`, `nf_nat`, `xt_MASQUERADE`,
  `xt_conntrack`).
- `lib/download-hits-*` stubs that symlink from the read-only dataset
  disk rather than `wget`ing from the public mirror.

Output: `/opt/clickbench-playground/base-rootfs.ext4` (a sparse 200 GB
ext4 image).

## 8. ClickHouse Cloud credentials (request logging)

The server appends every request and restart to a ClickHouse Cloud table.
Provide credentials either via `playground/.env`:

```
CLICKHOUSE_CLOUD_URL=https://your-host.clickhouse.cloud:8443
CLICKHOUSE_CLOUD_USER=default
CLICKHOUSE_CLOUD_PASSWORD=...
CLICKHOUSE_CLOUD_DB=playground
```

…or by copying `playground/clickhouse.conf.example` to
`/opt/clickbench-playground/clickhouse.conf` and filling it in.

If neither is configured, the server falls back to a local JSONL sink
under `/opt/clickbench-playground/logs/`.

## 9. Start the server

Foreground (for local development):

```
playground/scripts/run-server.sh
```

As a managed service (recommended for production):

```
sudo cp playground/clickbench-playground.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now clickbench-playground
```

The server listens on `:8000` (HTTP) and, if a TLS cert exists at
`/etc/letsencrypt/live/${PLAYGROUND_TLS_DOMAIN}/`, also on `:443`.

## 10. Provision every system (long)

The server doesn't auto-provision on first query — initial install/start/
load/snapshot is opt-in. Kick the whole catalog:

```
playground/scripts/provision-all.sh
```

This walks every system in `/api/systems`, posts to
`/api/admin/provision/<name>`, and polls until each one is either
`snapshotted` or `down` with an error. Concurrency is bounded server-side
by `PLAYGROUND_PROVISION_CONCURRENCY` (default 32) and
`PLAYGROUND_BUILD_CONCURRENCY` (default 6). Expect 1–6 hours of wall
time depending on host throughput and Docker Hub rate-limit luck.

Status: `curl http://localhost:8000/api/state | jq`.
Per-system log: `/opt/clickbench-playground/logs/provision-<name>.log`.

## 11. (Optional) Tune concurrency / monitor thresholds

Environment variables read at server startup:

| Var                              | Default                              | What it does                                              |
|----------------------------------|--------------------------------------|-----------------------------------------------------------|
| `PLAYGROUND_STATE_DIR`           | `/opt/clickbench-playground`         | host state root                                            |
| `PLAYGROUND_LISTEN`              | `0.0.0.0:8000`                       | HTTP listener                                              |
| `PLAYGROUND_TLS_CERT/_KEY`       | `/etc/letsencrypt/live/$DOMAIN/...`  | TLS                                                        |
| `PLAYGROUND_BUILD_CONCURRENCY`   | 6                                    | parallel per-system rootfs builds                          |
| `PLAYGROUND_PROVISION_CONCURRENCY` | 32                                  | parallel VM provisions                                     |
| `PLAYGROUND_SNAPSHOT_CONCURRENCY` | 6                                   | parallel Firecracker snapshot saves                        |
| `CLICKBENCH_OUTPUT_LIMIT`        | 262144                               | per-query response cap (bytes) enforced inside the agent   |
| `VM_CPU_BUSY_THRESHOLD`          | 0.97                                 | monitor: kill idle VMs above this                          |
| `VM_DISK_FULL_PCT`               | 0.97                                 | monitor: kill VMs whose sysdisk passes this                |

## Smoke-testing a single system

```
playground/scripts/smoke-boot.sh clickhouse
```

Boots one system end-to-end (provision → snapshot → restore → /query),
prints timing, tears down. Use this to validate any change to
`base-rootfs.ext4` or the agent before re-kicking the full catalog.

## Re-provisioning after agent or base-image changes

`vm_manager` rebuilds the per-system rootfs+sysdisk automatically when
`base-rootfs.ext4` is newer than the existing `rootfs.ext4`. So after
changing `playground/agent/agent.py` or anything baked into the base:

```
sudo playground/images/build-base-rootfs.sh    # rebuild base
curl -X POST http://localhost:8000/api/admin/provision/<name>   # re-kick
```

The new agent and new per-system scripts both land in the next provision.
