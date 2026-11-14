# ParticleDB

[ParticleDB](https://particledb.ai) is a proprietary database for AI agents
and applications. This entry uses `1.1.19-rc.16` with durable `pdb_segment` tables.

## Run

Use a fresh **c8g.metal-48xl** (192 vCPU, 384 GiB RAM), Ubuntu 24.04 ARM64
with systemd, a 500 GiB gp2 ext4 root disk, internet and passwordless sudo.
[install](install) downloads
the public [ARM64](https://get.particledb.ai/v1.1.19-rc.16/particledb-linux-arm64)
or [x86-64](https://get.particledb.ai/v1.1.19-rc.16/particledb-linux-x86_64)
binary (x86-64 requires AVX2), and checks its pinned SHA256.

From the checkout root, apply the host preparation used by ClickBench's
[EC2 setup](../cloud-init.sh.in), then run the benchmark:

```bash
sudo bash <<'SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
if [ ! -f /swapfile ]; then
  fallocate -l 16G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
mount -o remount,noinit_itable /
apt-get update -y
apt-get install -y wget curl git jq earlyoom tmux
systemctl enable --now earlyoom
SETUP
./particledb/benchmark.sh
```

Use tmux for an interactive SSH session.

## Benchmark details

- The bundled native CLI loads `hits.parquet` into the standard 105-column
  schema using `pdb_segment` and verifies that the connection uses native wire.
  Load timing includes CREATE, COPY, verification of 99,997,497 rows and sync;
  download is excluded.
- Uses optimistic concurrency control and sync durability. `C` collation
  deliberately selects byte-order text comparison instead of the release's
  locale-aware default; it applies to every query. Memory and parallelism use
  release defaults, with no query-specific tuning.
- Query-result caching is disabled.
- Four loopback listeners remain: the SQL compatibility listener, the shared
  native/HTTP/gRPC/health listener, Redis and metrics.
  Console, MySQL and Unix sockets are disabled; rc.16 cannot
  disable the remaining auxiliary listeners.
- Uses the unchanged shared driver and 43 standard queries. Each query runs
  three times: one cold execution after database shutdown, OS cache clearing
  and restart, followed by two hot executions. ParticleDB's native CLI measures
  client-side query time including the full result transfer. Loading, readiness
  checks and timed queries all use the same bundled native client.
- Runs the standard concurrent phase with 10 workers for 600 seconds.
- Data size includes WAL and metadata, excluding the downloaded Parquet file.

The [result](results/20261031/c8g.metal-48xl.json) was measured on a fresh
instance using upstream revision `ec8a4ee41a82345db45714dcde0a17bcd54a3128`.

Timings are in `particledb/result.csv`. Each install creates a fresh directory
under `particledb/runs/` for data, version, hash and server log;
`particledb/current-run` points to it. systemd waits for complete shutdown.
