# Playground build progress — checkpoint 2026-05-12 ~21:30 UTC

## Status: ClickHouse end-to-end works

```
$ printf 'SELECT COUNT(*) FROM hits' | curl -sS -X POST --data-binary @- \
    'http://127.0.0.1:8000/api/query?system=clickhouse' -D -
HTTP/1.1 200 OK
X-Query-Wall-Time: 0.122721
X-Output-Bytes: 9
X-Output-Truncated: 0
X-Query-Time: 0.003000
X-Wall-Time: 10.112950
Content-Length: 9

99997497
```

Cold path (snapshot restore + daemon start): ~10 s.
Warm path (live VM): subsecond on COUNT / MIN-MAX, ~24 s on top-of-URL.
Output truncation: 244 KB result correctly capped to 10 KB with
`X-Output-Truncated: 1` set.

## Snapshot footprint

`snapshot.bin.zst` for ClickHouse: **35 MB** (down from 16 GB raw RAM dump,
~470× compression). The combination that gets us there:

  1. Agent stops the daemon at the end of /provision (clickhouse stop).
  2. Agent drops the page+dentry+inode cache.
  3. Guest kernel runs with `init_on_free=1` — every freed page is
     zero-filled before going back on the free list, so the resulting
     RAM is genuinely compressible (not just "freed-but-stale" stale
     bytes that look random to zstd).
  4. Host calls a /sync endpoint on the agent immediately before
     /vm Paused, so ext4 writeback completes before KVM freezes the
     vcpus — no half-flushed pages in the snapshot.
  5. `zstd -T0 -3 --long=27` for parallel compression with a 128 MB
     match window (helps with repetitive zero patterns).

On restore the agent's first /query brings the daemon back up via
`_ensure_daemon_started`. That's ~3-5 s of clickhouse startup amortized
into the first cold query.

## Components shipped

- `playground/server/` — aiohttp API (UI + /api/{systems,system,query,
  state,admin/provision,provision-log}), per-system Firecracker
  lifecycle, monitor watchdog, batched ClickHouse-Cloud logging sink
  with JSONL fallback.
- `playground/agent/` — stdlib HTTP agent. Endpoints:
  - GET /health, /stats, /provision-log
  - POST /provision (install → start → check → load → stop → drop_caches)
  - POST /sync (guest fsync just before host snapshot)
  - POST /query (256 KB output cap, fractional-second timing in headers)
- `playground/images/` — `build-base-rootfs.sh` (Ubuntu 24.04 → flat 8 GB
  ext4 with agent pre-installed), `build-system-rootfs.sh` (per-system
  200 GB sparse rootfs + sized system disk with pre-staged dataset).
- `playground/web/` — vanilla-JS SPA with system picker, query box,
  timing display, truncation indicator.

## Host state

```
/opt/clickbench-playground/
├── bin/firecracker, bin/jailer        firecracker v1.13.1
├── kernel/vmlinux                     Linux 6.1.141
├── base-rootfs.ext4                   2.6 GB physical / 8 GB apparent
├── datasets/
│   ├── hits.parquet                   14.7 GB
│   ├── hits_partitioned/              14 GB (100 files)
│   ├── hits.tsv                       74 GB
│   ├── hits.csv                       partial (kill-stopped); .gz intact
└── systems/clickhouse/
    ├── rootfs.ext4                    sparse 200 GB
    ├── system.ext4                    16 GB (parquet + scripts)
    ├── snapshot.bin.zst               35 MB
    └── snapshot.state                 58 KB
```

## What's left

- Build system disks for the remaining 96 systems (template is ready;
  each requires its own provision pass — most should "just work" with
  the same flow).
- Tighten the External-only exclusion list in `systems.py` once we've
  validated which local-only systems actually run.
- Wire ClickHouse Cloud credentials for the logging sink (currently
  falling back to JSONL under `/opt/clickbench-playground/logs/`).
- Optional: jailer integration for tighter isolation if the host is
  ever multi-tenant.

## Known sharp edges

- The `chroot` in `build-base-rootfs.sh` previously tore down the host's
  `/dev/pts` via mount propagation, breaking sshd PTY allocation. Fixed
  with `mount --make-rslave` (committed); if you see "PTY allocation
  request failed on channel 0" after a rebuild, `sudo mount -t devpts
  devpts /dev/pts -o gid=5,mode=620,ptmxmode=000` brings it back.
- KVM permissions: a udev rule at `/etc/udev/rules.d/65-kvm.rules` keeps
  `/dev/kvm` group=kvm mode=666 so the playground user can open it.
- `vm.dirty_writeback_centisecs=10` on the host (down from 500); revert
  if it causes problems elsewhere.
