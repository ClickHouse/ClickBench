# Playground build progress — checkpoint 2026-05-12 ~19:58 UTC

## What is built and committed

- `playground/` directory scaffolded with subdirs `server/`, `agent/`,
  `images/`, `web/`, `scripts/`, `docs/`.
- Architecture notes in `playground/README.md` and
  `playground/docs/architecture.md`.
- Host-side API server (`playground/server/*.py`):
  - `config.py` — env-driven config with sensible defaults
  - `systems.py` — discovers 97 playground-eligible ClickBench systems
  - `firecracker.py` — async unix-socket client for Firecracker API
  - `net.py` — per-VM TAP + /24 + NAT toggle
  - `vm_manager.py` — VM lifecycle (boot, provision, snapshot, restore)
  - `monitor.py` — CPU/disk/host-memory watchdog (1 Hz)
  - `logging_sink.py` — batched async logger → ClickHouse Cloud + JSONL fallback
  - `main.py` — aiohttp routes + static SPA serving
- In-VM agent (`playground/agent/agent.py`, stdlib-only) with endpoints
  `/health`, `/stats`, `/provision`, `/query`, `/provision-log`.
- systemd unit `playground/agent/clickbench-agent.service` installed in the
  rootfs and enabled.
- Vanilla JS SPA (`playground/web/`): system picker, query box, timing display,
  truncation indicator. Talks to `/api/systems`, `/api/system/<name>`,
  `/api/query?system=...`.
- Build scripts:
  - `images/build-base-rootfs.sh` — Ubuntu 22.04 cloud image → flat 8 GB
    ext4 with agent + systemd unit pre-installed.
  - `images/build-system-rootfs.sh` — per-system 200 GB sparse rootfs +
    sized system disk (16/88 GB depending on data format) containing the
    ClickBench scripts + the dataset files this system needs (no symlinks
    into a RO mount, because many systems' load scripts `chown`).
  - `scripts/install-firecracker.sh` — idempotent host setup.
  - `scripts/download-datasets.sh` — eager dataset download into
    `/opt/clickbench-playground/datasets/`.
  - `scripts/smoke-boot.sh` — boots the base rootfs alone in a VM; confirms
    kernel + rootfs + agent path before per-system testing.
  - `scripts/agent-selftest.sh` — runs the agent on the host (no VM) and
    exercises all endpoints with a fake "system" dir. PASSES.

## What is provisioned on disk (host)

```
/opt/clickbench-playground/
├── bin/firecracker, bin/jailer       (firecracker v1.13.1)
├── kernel/vmlinux                    (Linux 6.1.141, IP_PNP + virtio enabled)
├── base-rootfs.ext4                  2.6 GB physical / 8 GB apparent
├── datasets/
│   ├── hits.parquet                  14.7 GB (single)
│   ├── hits_partitioned/             14 GB (100 partitioned files)
│   ├── hits.tsv                      74 GB (decompressed)
│   ├── hits.csv                      ~14 GB partial (kill-stopped)
│   └── hits.csv.gz                   16 GB
└── systems/clickhouse/
    ├── rootfs.ext4                   8.2 MB physical / 200 GB sparse
    └── system.ext4                   16 GB (parquet files staged)
```

## What works

- Python module imports clean (`python3 -m playground.server.main`).
- API server serves 97 systems via `/api/systems`.
- UI loads at `/ui/`.
- Firecracker smoke-boot (base rootfs only): agent comes up in 2 s,
  `/health` and `/stats` respond OK.
- Agent self-test (no VM): all 4 endpoints behave correctly, output
  truncation works (2 KB → 64 B with `X-Output-Truncated: 1`).
- Provision started on ClickHouse VM at 19:51:59 UTC:
  - VM booted, agent up, internet enabled via MASQUERADE on `ens33`
  - Install ran (ClickHouse binary downloaded + apt deps)
  - Load is in progress — `cpu_busy=0.8-1.0` sustained, `disk_used`
    grew from 17 GB → 30 GB, indicating MergeTree INSERT.
  - At 19:57:33 the agent stopped responding to /health (timeout).
    Firecracker process is still running (PID 19230, 16 min of CPU).
    Likely cause: agent's HTTP server starved by the load process,
    or a fork race in stdlib `socketserver`. Needs investigation.

## What's left

- Decide whether to add eager liveness pings or move agent to aiohttp
  to avoid the stdlib threading server's quirks under heavy load.
- Once provision completes: snapshot → restore → /query test path.
- Build system disks for the other 96 systems (template is ready).
- Wire up ClickHouse Cloud credentials for the logging sink (currently
  falling back to JSONL under `/opt/clickbench-playground/logs/`).

## Known issues / things to revisit

- TSV/CSV decompression contends with rootfs build for nvme writeback.
  Workaround: pre-build the base rootfs before kicking off the heavy
  decompressions, or rate-limit pigz.
- The "External" exclusion list in `systems.py` is conservative; some
  entries (umbra, hyper, cedardb) actually run locally and should be
  added back when verified.
- /etc/resolv.conf in the base rootfs is a static fallback (1.1.1.1 +
  8.8.8.8). Once we cut internet post-snapshot, DNS doesn't matter, but
  during provision it does — sanity check that NAT + resolv.conf actually
  let `apt-get update` work.
- KVM permissions were opened to mode 666 via a udev rule. Tighten to
  the `kvm` group when the playground user is properly added.

## Operator notes

- The base rootfs ships with serial autologin as root on ttyS0 — good for
  attaching the Firecracker console for debugging.
- Firecracker logs land in `/opt/clickbench-playground/logs/firecracker-<system>.log`.
- The host's `/dev/kvm` group/mode was changed: `chown root:kvm`, `chmod 666`,
  with a persistent udev rule at `/etc/udev/rules.d/65-kvm.rules`.
- `vm.dirty_writeback_centisecs` is set to 10 on the host (down from 500)
  to reduce sfdisk hang during heavy concurrent writeback. Revert if it
  causes other problems.
