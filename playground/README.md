# ClickBench Playground

A self-service playground that lets visitors run arbitrary SQL against any of the
80+ database systems documented in ClickBench, isolated inside a Firecracker
microVM per system.

## How it works

1. The dataset (hits, in all formats ClickBench uses) is downloaded once into a
   single directory on the host and exposed read-only to every VM as a virtio-blk
   device.
2. For each system, a Firecracker microVM is launched once with internet access
   to run the system's `install`, `start`, and `load` scripts.
3. A snapshot (memory + disk) is taken and persisted. Subsequent restorations
   run without internet — the only path in or out is the host↔VM control link.
4. A small in-VM **agent** exposes `POST /query` over HTTP. The host **API
   server** proxies user queries to the agent, returns the raw output as
   `application/octet-stream`, and puts the timing into response headers.
5. A **monitor** loop watches per-VM CPU/disk/memory and host totals, killing
   misbehaving or oversized VMs.
6. Every request and every restart is appended to a ClickHouse Cloud table.

## Layout

```
playground/
├── server/    # aiohttp API server, VM manager, monitor, logging sink
├── agent/     # In-VM HTTP agent (runs as systemd unit inside each VM)
├── images/    # Scripts that build the base rootfs + per-system overlays
├── web/       # Vanilla-JS single-page app
├── scripts/   # Host-side install / dataset / network helpers
└── docs/      # Design notes
```

Host state lives under `/opt/clickbench-playground/`:

```
/opt/clickbench-playground/
├── bin/                   firecracker, jailer
├── kernel/vmlinux         guest kernel
├── base-rootfs.ext4       pristine Ubuntu 22.04 rootfs (built once)
├── datasets/              hits.parquet, hits_*.parquet, hits.tsv, hits.csv
├── datasets.ext4          read-only image of datasets/ (attached to every VM)
├── systems/<name>/        per-system rootfs, snapshot, sockets, logs
├── vms/<name>.sock        Firecracker API socket
└── logs/                  local JSONL fallback when ClickHouse Cloud is off
```

## Networking

Each VM gets its own `/30` subnet on a dedicated TAP:

| Side | Address          | Notes                          |
|------|------------------|--------------------------------|
| Host | `10.200.<id>.1`  | TAP device `fc-tap-<name>`     |
| VM   | `10.200.<id>.2`  | reachable from host always     |

During the install phase, `iptables FORWARD` + MASQUERADE are enabled for the
TAP so the VM can `apt-get`/`curl`/etc. After the snapshot is taken, the
forwarding rules are removed; the host↔VM link still works but external traffic
is blackholed.

## Configuration

Environment variables (read by `server/config.py`):

| Var                            | Purpose                                       |
|--------------------------------|-----------------------------------------------|
| `CLICKHOUSE_CLOUD_URL`         | HTTPS URL of CH Cloud (e.g. `https://x.clickhouse.cloud:8443`) |
| `CLICKHOUSE_CLOUD_USER`        | username                                      |
| `CLICKHOUSE_CLOUD_PASSWORD`    | password                                      |
| `PLAYGROUND_STATE_DIR`         | defaults to `/opt/clickbench-playground`      |
| `PLAYGROUND_LISTEN`            | defaults to `0.0.0.0:8000`                    |
| `PLAYGROUND_MAX_VMS`           | concurrent live VMs cap (default 16)          |
| `PLAYGROUND_OUTPUT_LIMIT`      | response body cap in bytes (default 10240)    |

## Lifecycle of a request

```
client ──HTTP──▶ api/query?system=clickhouse
                            │
                            ▼
                  vm_manager.ensure_ready("clickhouse")
                  ├─ already running and /health OK ──▶ proceed
                  ├─ not running ──▶ restore from snapshot
                  └─ unresponsive ──▶ kill, restore, retry once
                            │
                            ▼
                  agent ◀── POST /query ── body=SQL
                  agent runs ./query, captures stdout/stderr, returns:
                      Content-Type: application/octet-stream
                      X-Query-Time: 0.234
                      X-Output-Truncated: 0|1
                      X-Output-Bytes: 8042
                      body: (up to 10 KB of raw output)
                            │
                            ▼
                  logger.write_request(...)
                            │
                            ▼
                            client
```
