# ClickBench Playground architecture

## Components

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          Browser (vanilla JS)                            │
│  picks a system, types SQL, POST /api/query                              │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ HTTP/1.1
┌────────────────────────────▼─────────────────────────────────────────────┐
│                       Host API server (aiohttp)                          │
│  ┌─────────────────┐   ┌──────────────┐   ┌────────────────┐             │
│  │ HTTP routes     │   │ VMManager    │   │ Monitor        │             │
│  │ /api/systems    │   │   per-VM     │   │ 1Hz polling    │             │
│  │ /api/query      │──▶│   lifecycle  │◀──│ CPU/mem/disk   │             │
│  │ /api/state      │   │   snapshots  │   │ watchdog       │             │
│  └─────────────────┘   └──────┬───────┘   └────────────────┘             │
│  ┌─────────────────────────────▼─────────────────────────────────────┐   │
│  │ LoggingSink: batched INSERT into ClickHouse Cloud + local JSONL   │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ HTTP over per-VM TAP /24
┌────────────────────────────▼─────────────────────────────────────────────┐
│   Firecracker microVM  (Ubuntu 22.04, 4 vCPU / 16 GB / 200 GB sparse)    │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │ in-VM agent (stdlib python HTTP server)                          │   │
│   │   /health, /stats, /provision, /query                            │   │
│   └────────────────────────┬─────────────────────────────────────────┘   │
│                            ▼ runs                                        │
│   ┌──────────────────────────────────────────────────────────────────┐   │
│   │ /opt/clickbench/system/ — system's ClickBench scripts (RW)       │   │
│   │ /opt/clickbench/datasets/ — shared dataset image (RO)            │   │
│   └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

## State machine (per system)

```
                    ┌───────┐  no snapshot ┌───────────────┐
                    │ down  │─────────────▶│ provisioning  │
                    └───┬───┘              └───────┬───────┘
                        │                          │ provision OK
                        │       snapshot ok        ▼
                        │                  ┌──────────────┐
                        ▼                  │ snapshotted  │
                  ┌───────────┐ restore    └──────┬───────┘
                  │  ready    │◀────────────────  │
                  └─────┬─────┘                   │
                        │ watchdog / failed query │
                        └─────────────────────────┘
```

`ready` is the only state that accepts /query. Any restart (watchdog or
explicit kick) returns to `snapshotted`; the next /query restores from the
on-disk snapshot.

## Snapshots

Created the first time a system is requested. Three artifacts:

- `<state>/systems/<name>/snapshot.state`        — Firecracker VM metadata
- `<state>/systems/<name>/snapshot.bin`          — guest memory dump
  (mmap'd by Firecracker on restore — left uncompressed so restore is
  O(1) host work; pages fault in lazily)
- `<state>/systems/<name>/{rootfs,system}.golden.ext4` — frozen disk
  state at snapshot time, reflink-cloned at restore

The host filesystem at `<state>` **must support reflinks** (XFS, or
ext4 with `shared_blocks`). `_snapshot_disks` and `_restore_disks` both
use `cp --reflink=always` so cloning the golden into a working disk is
a constant-time extent-list copy regardless of how much data the system
actually wrote. Without reflinks the playground still works, but every
restore pays a full sparse-cp of the working set.

Snapshots are taken with the daemon **running** (`./start` is invoked
after the pre-snapshot `./stop` + `fstrim` + `drop_caches`), so a
restored VM resumes with the daemon already serving — no cold-start
cost on the first query.

Drive paths in the snapshot are remapped to their current host locations
on restore so we don't have to re-snapshot if the playground gets moved
or rebooted.

## Networking

A `/24` per VM, with the host owning `.1` and the guest owning `.2`. Each
TAP is `fc-tap-<slot>`, where `<slot>` is the deterministic per-system index
assigned in `VMManager.__init__`.

```
host  10.200.<slot>.1/24  ◀── TAP ─▶  10.200.<slot>.2/24  guest
```

During the provision phase only, iptables NAT/FORWARD rules are added so
the guest can `apt-get` / `curl`. After the snapshot, those rules are
deleted — outbound traffic is dropped, the host↔guest link remains.

## Output truncation

Truncation is applied **inside the agent**, before bytes leave the VM:

- Stdout from the system's `./query` script is capped at
  `CLICKBENCH_OUTPUT_LIMIT` bytes (default 256 KB).
- The agent's response sets `X-Output-Truncated: 1` and
  `X-Output-Bytes: <untruncated-size>` so the client can show "this is a
  partial result of N bytes."
- The host API server passes the headers through unchanged.

## Watchdog rules

The `Monitor` thread samples every running Firecracker process once per
second:

- **CPU**: if per-VM CPU usage (utime+stime / wallclock / vcpus) stays
  ≥ `VM_CPU_BUSY_THRESHOLD` (default 97%) for `VM_CPU_BUSY_WINDOW_SEC`
  contiguous seconds (default 120), the VM is killed.
- **Disk**: if the sparse `rootfs.ext4` has allocated more than
  `VM_DISK_FULL_PCT` (default 97%) of `VM_ROOTFS_SIZE_GB`, the VM is
  killed.
- **Host RAM**: if `MemAvailable` drops below `HOST_MIN_FREE_RAM_GB`
  (default 32 GiB), the watchdog kills the VM with the largest RSS.
- **Host disk**: if free space on `PLAYGROUND_STATE_DIR` drops below
  `HOST_MIN_FREE_DISK_GB` (default 500 GiB), the watchdog kills the VM
  with the largest allocated rootfs.

A "kill" leaves the snapshot intact. The next user query restores from
snapshot, paying ~1 s of memory restore cost.
