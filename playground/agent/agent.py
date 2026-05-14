#!/usr/bin/env python3
"""
ClickBench in-VM agent.

Runs inside the Firecracker microVM. Exposes a tiny HTTP API that the host
server hits to:

  GET  /health             quick liveness probe; cheap
  GET  /stats              CPU/mem/disk snapshot
  POST /provision          run install -> start -> load for the bundled system
                           (only called once, before the host snapshots the VM)
  POST /query              read SQL from request body, exec ./query, return
                           output as application/octet-stream + timing headers

The system's ClickBench scripts (install/start/load/query/check/stop/...) are
mounted at /opt/clickbench/system, with the system name in /etc/clickbench-
system. The dataset is mounted read-only at /opt/clickbench/datasets.

Listens on 0.0.0.0:50080 by default (deliberately not 8080 — that port
is claimed by cockroach, spark UI, trino, presto, druid, and a long
tail of other JVM web consoles in the catalog).

Stdlib-only — the rootfs ships python3 from the Ubuntu base; no pip needed.
"""

from __future__ import annotations

import contextlib
import http.server
import json
import os
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

SYSTEM_DIR = Path(os.environ.get("CLICKBENCH_SYSTEM_DIR", "/opt/clickbench/system"))
DATASETS_DIR = Path(os.environ.get("CLICKBENCH_DATASETS_DIR", "/opt/clickbench/datasets_ro"))
STATE_DIR = Path(os.environ.get("CLICKBENCH_AGENT_STATE", "/var/lib/clickbench-agent"))
SYSTEM_NAME = (
    os.environ.get("CLICKBENCH_SYSTEM_NAME")
    or (Path("/etc/clickbench-system").read_text().strip()
        if Path("/etc/clickbench-system").exists() else SYSTEM_DIR.name)
)
# Port 8080 is wildly oversubscribed in this catalog (cockroach, spark UI,
# trino, presto, hive, druid, ...). Pick a port nothing realistic is going
# to want — IANA's user range tops out at 49151, and we want to stay above
# any well-known ephemeral range too. 50080 keeps a vague "HTTP-ish" feel.
LISTEN_PORT = int(os.environ.get("CLICKBENCH_AGENT_PORT", "50080"))
# 10 KB cap, matching the spec. Configurable for testing.
OUTPUT_LIMIT = int(os.environ.get("CLICKBENCH_OUTPUT_LIMIT", str(256 * 1024)))
# Per-query wall-clock cap so a runaway query can't tie up a VM forever.
QUERY_TIMEOUT = int(os.environ.get("CLICKBENCH_QUERY_TIMEOUT", "60"))
# Provision (install/start/load) can legitimately take an hour for some systems.
# Per-step timeout for install/start/load. Some real-world systems load
# 100 M rows over many hours (postgres + indexes, cratedb, cockroachdb,
# yugabyte, etc.). 7 days covers anything reasonable without being
# unbounded.
PROVISION_TIMEOUT = int(os.environ.get("CLICKBENCH_PROVISION_TIMEOUT", str(7 * 86400)))

STATE_DIR.mkdir(parents=True, exist_ok=True)
PROVISION_DONE = STATE_DIR / "provisioned"
PROVISION_LOG = STATE_DIR / "provision.log"

# Single-writer lock; the agent serializes queries per VM. Two ClickBench
# scripts hitting the same socket/temp file concurrently would not be safe.
_query_lock = threading.Lock()
_provision_lock = threading.Lock()
# Tracks whether we've successfully run ./start since this agent process
# came up. After a snapshot restore the daemon doesn't exist in the
# restored memory (we stop it pre-snapshot to keep snapshots small), so the
# first /query has to bring it up.
_daemon_started = threading.Event()
_daemon_lock = threading.Lock()


def _cap(b: bytes) -> tuple[bytes, bool]:
    """Truncate to OUTPUT_LIMIT bytes; return (body, was_truncated)."""
    if len(b) <= OUTPUT_LIMIT:
        return b, False
    return b[:OUTPUT_LIMIT], True


def _read_body(handler: http.server.BaseHTTPRequestHandler) -> bytes:
    n = int(handler.headers.get("Content-Length") or 0)
    if n <= 0:
        return b""
    # Cap inbound bodies at 1 MB; queries are SQL, not bulk data.
    return handler.rfile.read(min(n, 1 << 20))


def _system_script(name: str) -> Path:
    """Return path to a script in the system dir, or raise if missing/not executable."""
    p = SYSTEM_DIR / name
    if not p.exists():
        raise FileNotFoundError(f"missing system script: {p}")
    if not os.access(p, os.X_OK):
        raise PermissionError(f"system script not executable: {p}")
    return p


def _read_proc_stat() -> tuple[int, int]:
    """Return (total_jiffies, idle_jiffies) from /proc/stat."""
    with open("/proc/stat") as f:
        parts = f.readline().split()
    nums = list(map(int, parts[1:]))
    total = sum(nums)
    idle = nums[3] + (nums[4] if len(nums) > 4 else 0)
    return total, idle


def _stats_snapshot() -> dict:
    out: dict = {"system": SYSTEM_NAME, "ts": time.time()}
    try:
        out["loadavg"] = list(map(float, Path("/proc/loadavg").read_text().split()[:3]))
    except Exception:
        pass
    try:
        info = {k: v for k, v in (
            l.split(":", 1) for l in Path("/proc/meminfo").read_text().splitlines() if ":" in l
        )}
        out["mem_total_kb"] = int(info.get("MemTotal", "0 kB").split()[0])
        out["mem_avail_kb"] = int(info.get("MemAvailable", "0 kB").split()[0])
    except Exception:
        pass
    try:
        st = shutil.disk_usage("/")
        out["disk_total"] = st.total
        out["disk_free"] = st.free
    except Exception:
        pass
    try:
        t1, i1 = _read_proc_stat()
        time.sleep(0.05)
        t2, i2 = _read_proc_stat()
        total = max(1, t2 - t1)
        out["cpu_busy"] = 1.0 - (i2 - i1) / total
    except Exception:
        pass
    out["provisioned"] = PROVISION_DONE.exists()
    return out


def _ensure_daemon_started() -> None:
    """Bring the system's daemon up if it isn't already.

    Called at the top of every /query handler. The first call after a
    snapshot restore is where the work happens — the snapshot was taken
    with the daemon stopped (to keep the memory image compressible), so
    nothing is listening on the daemon's port until we explicitly run
    ./start. Subsequent calls are no-ops because _daemon_started is set.

    Wrapping ./start in a thread lock means only one /query in flight
    pays the start cost, even if several arrive concurrently.
    """
    if _daemon_started.is_set():
        return
    with _daemon_lock:
        if _daemon_started.is_set():
            return
        start = SYSTEM_DIR / "start"
        if not start.exists() or not os.access(start, os.X_OK):
            # No daemon to start (in-process system like chdb/polars).
            _daemon_started.set()
            return
        subprocess.run([str(start)], cwd=str(SYSTEM_DIR),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=300, check=False)
        # Wait for ./check to confirm before unblocking the /query.
        check = SYSTEM_DIR / "check"
        if check.exists():
            for _ in range(120):
                rc = subprocess.run([str(check)], cwd=str(SYSTEM_DIR),
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    timeout=10, check=False).returncode
                if rc == 0:
                    break
                time.sleep(0.5)
        _daemon_started.set()


def _run_query(sql: bytes) -> tuple[int, bytes, bytes, float]:
    """
    Invoke ./query with the SQL on stdin.
    The query script's contract per lib/benchmark-common.sh:
      stdout: result (whatever format the system uses)
      stderr: timing in fractional seconds on the LAST numeric line
      exit code: 0 on success

    Stops reading stdout once we've buffered OUTPUT_LIMIT+1 bytes (one
    extra so _cap can detect the overflow) and kills the process group —
    "SELECT * FROM hits" generates ~14 GB of output and we don't want
    the agent to spin buffering it. Stderr is read on a background
    thread so a chatty stderr can't deadlock the stdout pipe.
    """
    import select
    import threading
    script = _system_script("query")
    t0 = time.monotonic()
    deadline = t0 + QUERY_TIMEOUT
    cap = OUTPUT_LIMIT + 1  # +1 byte so _cap() can detect overflow
    stdout_buf = bytearray()
    stderr_buf = bytearray()
    try:
        p = subprocess.Popen(
            [str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(SYSTEM_DIR),
            preexec_fn=os.setsid,
        )
    except Exception as e:
        return 255, b"", f"agent: failed to invoke ./query: {e}\n".encode(), 0.0

    def _drain_stderr() -> None:
        for chunk in iter(lambda: p.stderr.read(8192), b""):
            stderr_buf.extend(chunk)
    err_thread = threading.Thread(target=_drain_stderr, daemon=True)
    err_thread.start()

    try:
        if sql:
            p.stdin.write(sql)
        p.stdin.close()
    except BrokenPipeError:
        pass

    killed_for = ""  # "timeout", "cap", or ""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            killed_for = "timeout"
            break
        if len(stdout_buf) >= cap:
            killed_for = "cap"
            break
        r, _, _ = select.select([p.stdout], [], [], min(remaining, 0.5))
        if r:
            chunk = p.stdout.read1(min(8192, cap - len(stdout_buf)))
            if not chunk:
                break  # EOF
            stdout_buf.extend(chunk)
        elif p.poll() is not None:
            break

    if killed_for:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(p.pid, signal.SIGKILL)

    try:
        rc = p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(p.pid, signal.SIGKILL)
        rc = -9

    if killed_for == "timeout":
        rc = -9
    err_thread.join(timeout=2)
    with contextlib.suppress(Exception):
        p.stdout.close()
    with contextlib.suppress(Exception):
        p.stderr.close()
    return rc, bytes(stdout_buf), bytes(stderr_buf), time.monotonic() - t0


def _extract_script_timing(stderr: bytes) -> float | None:
    """
    Pull fractional-seconds timing from the last numeric line of stderr,
    matching the lib/benchmark-common.sh tail -n1 logic.
    """
    # Handle the spark/pyspark carriage-return progress-bar case.
    text = stderr.decode("utf-8", errors="replace").replace("\r", "\n")
    last = None
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            v = float(s)
        except ValueError:
            continue
        last = v
    return last


def _provision() -> tuple[int, bytes]:
    """
    Run install -> start -> wait-for-check -> load. Capture everything to
    PROVISION_LOG. Idempotent: subsequent calls succeed-fast if PROVISION_DONE
    is present.
    """
    if PROVISION_DONE.exists():
        return 0, b"already provisioned\n"

    with _provision_lock:
        if PROVISION_DONE.exists():
            return 0, b"already provisioned\n"

        # Use the same /lib/benchmark-common.sh helpers if they're around. But
        # since this is the playground, we want a *minimal* version: install,
        # start, wait for check, load, sync. No cold-cycle restart, no
        # concurrent-QPS test, no query loop.
        steps: list[tuple[str, list[str]]] = [
            ("install", [str(_system_script("install"))]),
            ("start", [str(_system_script("start"))]),
        ]

        log_lines: list[bytes] = []
        for name, cmd in steps:
            t0 = time.monotonic()
            log_lines.append(f"\n=== {name} ===\n".encode())
            r = subprocess.run(
                cmd, cwd=str(SYSTEM_DIR),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=PROVISION_TIMEOUT,
            )
            dt = time.monotonic() - t0
            log_lines.append(r.stdout or b"")
            log_lines.append(f"=== {name} done rc={r.returncode} in {dt:.1f}s ===\n".encode())
            if r.returncode != 0:
                PROVISION_LOG.write_bytes(b"".join(log_lines))
                return r.returncode, b"".join(log_lines)

        # Wait for ./check to succeed for up to 300s
        check = SYSTEM_DIR / "check"
        ok = False
        t0 = time.monotonic()
        last_check: subprocess.CompletedProcess | None = None
        # Druid / Pinot / similar JVM-stack engines need 5-10 min to come
        # up from a cold start, between Zookeeper / Coordinator / Broker /
        # Historical processes booting in sequence. 300 s was too tight
        # for those; 900 s covers the slowest observed cases.
        while time.monotonic() - t0 < 900:
            last_check = subprocess.run(
                [str(check)], cwd=str(SYSTEM_DIR),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if last_check.returncode == 0:
                ok = True
                break
            time.sleep(1)
        if not ok:
            log_lines.append(b"\n=== check did not succeed within 900s ===\n")
            if last_check is not None:
                log_lines.append(last_check.stderr or b"")
            PROVISION_LOG.write_bytes(b"".join(log_lines))
            return 1, b"".join(log_lines)
        log_lines.append(b"\n=== check ok ===\n")

        # No explicit data staging — the system's load script sees
        # hits.parquet / hits.tsv / hits.csv / hits_*.parquet at cwd
        # already, because cwd is the overlay merged dir
        # /opt/clickbench/system and the dataset disk's contents (the
        # overlay's lower) sit at /opt/clickbench/datasets_ro at the
        # filesystem root, matching the names the load scripts use.

        # Run load.
        t0 = time.monotonic()
        log_lines.append(b"\n=== load ===\n")
        r = subprocess.run(
            [str(_system_script("load"))], cwd=str(SYSTEM_DIR),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=PROVISION_TIMEOUT,
        )
        dt = time.monotonic() - t0
        log_lines.append(r.stdout or b"")
        log_lines.append(f"=== load done rc={r.returncode} in {dt:.1f}s ===\n".encode())
        if r.returncode != 0:
            PROVISION_LOG.write_bytes(b"".join(log_lines))
            return r.returncode, b"".join(log_lines)

        # Pre-snapshot housekeeping. Order:
        #   1) ./stop  — drop the daemon's heap (merge arenas, query cache,
        #      mark cache, parquet ingest buffers, ...) so we can fstrim
        #      and drop_caches against a quiet system.
        #   2) sync + drop_caches — flush dirty pages, evict the page
        #      cache, so init_on_free=1 zeroes everything that was
        #      cache. Snapshot then sees a mostly-zero free pool.
        #   3) fstrim — DISCARD free blocks on the per-VM disks so the
        #      sparse backing file punches holes for bytes the load
        #      script `mv`'d in and `rm`'d (14-75 GB of dataset).
        #   4) ./start + ./check — bring the daemon back up *into* the
        #      snapshot. Restore then resumes a daemon that's already
        #      serving, paying zero cold-start cost.
        # Skip stop/start for systems without a real daemon (chdb,
        # polars, duckdb): they're in-process tools with no separate
        # process to manage.
        #
        # Also skip for daemons whose data lives only in their own
        # process address space (daft, pandas, chdb-dataframe, ...).
        # The default stop/restart wipes the loaded DataFrame and the
        # restored snapshot serves queries against a daemon whose
        # `hits = None`. A marker file in the system dir opts out.
        stop = SYSTEM_DIR / "stop"
        start = SYSTEM_DIR / "start"
        check = SYSTEM_DIR / "check"
        preserve_state = (SYSTEM_DIR / ".preserve-state").exists()
        has_daemon = (stop.exists() and start.exists() and
                      check.exists() and os.access(stop, os.X_OK) and
                      os.access(start, os.X_OK) and
                      not preserve_state)
        if preserve_state:
            # The daemon is already running with state we want to keep
            # (loaded DataFrame), so we don't restart it. The snapshot
            # ships it as-is — mark /ready before snapshot so the host
            # doesn't wait the full 600 s after restore.
            _daemon_started.set()
        if has_daemon:
            log_lines.append(b"\n=== pre-snapshot stop ===\n")
            r = subprocess.run([str(stop)], cwd=str(SYSTEM_DIR),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=120, check=False)
            log_lines.append(b"stop: rc=" + str(r.returncode).encode() + b"\n")
            log_lines.append(r.stdout or b"")
            # Wait for the daemon to actually exit (./check failing means
            # it's gone). Tolerant if it never fails — we still proceed.
            for _ in range(120):
                rc = subprocess.run([str(check)], cwd=str(SYSTEM_DIR),
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    timeout=10, check=False).returncode
                if rc != 0:
                    break
                time.sleep(0.5)
            log_lines.append(b"=== pre-snapshot stop done ===\n")

        # Drop the page+dentry+inode cache. With init_on_free=1 set in
        # the guest kernel cmdline (see vm_manager._kernel_cmdline), every
        # page the kernel frees gets zero-filled before going back on the
        # free list, so what we snapshot is mostly-zero.
        subprocess.run(["sync"], check=False)
        try:
            Path("/proc/sys/vm/drop_caches").write_text("3\n")
        except Exception:
            pass

        # fstrim the per-VM disks so transient dataset bytes from
        # `mv hits.parquet ... ; rm` don't end up in the golden disk.
        for mnt in ("/opt/clickbench/sysdisk", "/"):
            subprocess.run(["fstrim", mnt],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=300, check=False)

        # Restart the daemon so the snapshot captures it *running*. The
        # restored VM then doesn't pay any cold-start cost; the daemon's
        # process state, JIT/class-cache, connection pools, etc. all
        # come back live.
        if has_daemon:
            log_lines.append(b"\n=== pre-snapshot start ===\n")
            r = subprocess.run([str(start)], cwd=str(SYSTEM_DIR),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=PROVISION_TIMEOUT, check=False)
            log_lines.append(r.stdout or b"")
            log_lines.append(b"start: rc=" + str(r.returncode).encode() + b"\n")
            # Wait for ./check before snapshotting — we want the daemon
            # actually accepting queries when the memory image is captured.
            ok = False
            t0 = time.monotonic()
            while time.monotonic() - t0 < 900:
                rc = subprocess.run([str(check)], cwd=str(SYSTEM_DIR),
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL,
                                    timeout=10, check=False).returncode
                if rc == 0:
                    ok = True
                    break
                time.sleep(0.5)
            if ok:
                log_lines.append(b"=== pre-snapshot start ok ===\n")
                _daemon_started.set()  # the snapshot ships a running daemon
            else:
                log_lines.append(b"=== pre-snapshot start: check did not "
                                 b"succeed in 900 s; snapshot will need a "
                                 b"cold start on restore ===\n")
            # Sync once more so any data the just-started daemon wrote
            # (lock files, sockets, recovery markers) is on disk before
            # the host snapshots the rootfs/sysdisk.
            subprocess.run(["sync"], check=False)

        PROVISION_DONE.write_text(f"ok {time.time()}\n")
        PROVISION_LOG.write_bytes(b"".join(log_lines))
        return 0, b"".join(log_lines)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "clickbench-agent/0.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[agent] " + (fmt % args) + "\n")

    def _send(self, code: int, body: bytes, headers: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", (headers or {}).pop("Content-Type", "application/json"))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj, default=str).encode() + b"\n",
                   {"Content-Type": "application/json"})

    def do_GET(self) -> None:
        if self.path == "/health":
            self._send_json(200, {"ok": True, "system": SYSTEM_NAME,
                                  "provisioned": PROVISION_DONE.exists()})
            return
        if self.path == "/ready":
            # True when the system's daemon is fully accepting queries.
            # The host uses this at restore time to gate VM-state="ready"
            # for slow daemons (Doris, Druid, Trino, etc.); without it
            # the first user query arrives mid-start and times out.
            ready = _daemon_started.is_set()
            self._send_json(200 if ready else 503,
                            {"ready": ready, "system": SYSTEM_NAME})
            return
        if self.path == "/check":
            # Run the system's ./check script. 200 = daemon responds,
            # 503 = it does not. The host calls this after a failed
            # /query to decide whether to teardown the VM.
            check = SYSTEM_DIR / "check"
            if not check.exists() or not os.access(check, os.X_OK):
                # No check script (in-process systems like chdb/duckdb).
                # Treat as healthy — there's no separate daemon to fail.
                self._send_json(200, {"ok": True, "no_check": True})
                return
            rc = subprocess.run(
                [str(check)], cwd=str(SYSTEM_DIR),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=10, check=False,
            ).returncode
            self._send_json(200 if rc == 0 else 503,
                            {"ok": rc == 0, "rc": rc})
            return
        if self.path == "/stats":
            self._send_json(200, _stats_snapshot())
            return
        if self.path == "/provision-log":
            data = PROVISION_LOG.read_bytes() if PROVISION_LOG.exists() else b""
            self._send(200, data, {"Content-Type": "text/plain; charset=utf-8"})
            return
        self._send_json(404, {"error": "not found", "path": self.path})

    def do_POST(self) -> None:
        if self.path == "/sync":
            # Flush all dirty pages to the virtio-blk devices. The host
            # calls this immediately before /snapshot/create so the
            # on-disk image captured in the snapshot is consistent with
            # what the in-memory page cache thinks is there. Without
            # this, a long-running daemon's writeback may still be in
            # flight when KVM pauses the vcpus, the snapshot freezes a
            # mid-flush state, and post-restore reads see torn or
            # checksum-mismatched data.
            t0 = time.monotonic()
            subprocess.run(["sync"], check=False)
            self._send(200, f"{time.monotonic() - t0:.3f}\n".encode(),
                       {"Content-Type": "text/plain"})
            return
        if self.path == "/provision":
            rc, log = _provision()
            self._send(200 if rc == 0 else 500, log[-OUTPUT_LIMIT:],
                       {"Content-Type": "text/plain; charset=utf-8",
                        "X-Provision-Status": "ok" if rc == 0 else f"err-{rc}"})
            return
        if self.path == "/query":
            if not PROVISION_DONE.exists():
                self._send_json(409, {"error": "not provisioned"})
                return
            sql = _read_body(self)
            if not sql.strip():
                self._send_json(400, {"error": "empty query"})
                return
            # First /query after a snapshot restore: start the daemon
            # (it was stopped pre-snapshot to keep snapshots small).
            # Subsequent calls are a near-instant no-op.
            _ensure_daemon_started()
            with _query_lock:
                rc, out, err, wall = _run_query(sql)
            script_t = _extract_script_timing(err)
            body, truncated = _cap(out)
            headers = {
                "Content-Type": "application/octet-stream",
                "X-Query-Wall-Time": f"{wall:.6f}",
                "X-Output-Bytes": str(len(out)),
                "X-Output-Truncated": "1" if truncated else "0",
                "X-Exit-Code": str(rc),
                "X-System": SYSTEM_NAME,
            }
            if script_t is not None:
                headers["X-Query-Time"] = f"{script_t:.6f}"
            # When _cap truncated the output the script was almost
            # certainly killed mid-write — its rc is non-zero (SIGPIPE
            # / SIGKILL) and stderr is full of "broken pipe"-style
            # noise. That's not a real query failure, so don't surface
            # it as an error: return 200 and let X-Output-Truncated=1
            # tell the UI to label the result accordingly.
            if rc != 0 and not truncated:
                # Surface a snippet of stderr so the client sees *something*.
                err_snip = err[-1024:].decode("utf-8", errors="replace")
                headers["X-Error"] = err_snip.replace("\n", " | ")[:512]
            self._send(200 if (rc == 0 or truncated) else 502, body, headers)
            return
        self._send_json(404, {"error": "not found", "path": self.path})


class ReusableServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def _reconcile_docker_after_restore() -> None:
    """Restart dockerd if it's active, to recover from snapshot-restore
    skew.

    Why: after a Firecracker memory snapshot+restore, dockerd is resumed
    in userspace but the (also-restored) kernel-side networking and cgroup
    state is in flux. Symptom: `docker run` either fails or starts a
    container that's unreachable on its mapped port (cedardb, byconity,
    trino, etc.). `systemctl restart docker` reconciles the daemon to the
    current kernel state. No-op on systems that don't use docker, and a
    cheap ~2 s on initial provision (docker was just started anyway).
    """
    rc = subprocess.run(
        ["systemctl", "is-active", "--quiet", "docker"],
        check=False,
    ).returncode
    if rc != 0:
        return  # docker isn't installed / not active
    try:
        subprocess.run(["sudo", "systemctl", "restart", "docker"],
                       check=False, timeout=60)
        # Wait for the daemon to come back.
        for _ in range(30):
            r = subprocess.run(["sudo", "docker", "info"],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL,
                               check=False, timeout=5).returncode
            if r == 0:
                return
            time.sleep(1)
    except Exception as e:
        sys.stderr.write(f"[agent] docker reconcile failed: {e}\n")


def _kick_daemon_if_provisioned() -> None:
    """On every agent boot, if the system has been provisioned, make sure
    the daemon is also running.

    The rootfs is persistent across boots, so PROVISION_DONE survives a
    cold restart of the VM. But the *process* doesn't — anything that was
    in the snapshot's memory image goes away when the host takes a cold
    boot (not a restore). Without this kick, a query would arrive at the
    agent, the agent would see PROVISION_DONE and skip install/start,
    and then ./query would hit a dead daemon and return "Connection
    refused (localhost:9000)" forever.

    Run start asynchronously: blocking the agent's listen until the
    daemon is ready would defeat /health, which the host uses to gate
    snapshot creation and restore-wait timeouts.
    """
    if not PROVISION_DONE.exists():
        return
    start = SYSTEM_DIR / "start"
    if not start.exists() or not os.access(start, os.X_OK):
        return

    def _bg() -> None:
        try:
            # Slow daemons (Doris, Druid, Trino) can take >5 min to come
            # up. The host's /ready poll has its own deadline; here we
            # only need a generous upper bound to prevent an infinite
            # hang.
            subprocess.run([str(start)], cwd=str(SYSTEM_DIR),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=900, check=False)
            check = SYSTEM_DIR / "check"
            if check.exists():
                # Poll ./check until it succeeds — that's the daemon's
                # own definition of "ready", and the host probes /ready
                # for this flag.
                for _ in range(240):
                    rc = subprocess.run([str(check)], cwd=str(SYSTEM_DIR),
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL,
                                        timeout=10, check=False).returncode
                    if rc == 0:
                        break
                    time.sleep(0.5)
            _daemon_started.set()
        except Exception as e:
            sys.stderr.write(f"[agent] daemon-kick failed: {e}\n")
            # Still mark started so /query is unblocked even if the
            # daemon never comes up — the query will fail with a real
            # error rather than hang waiting for /ready forever.
            _daemon_started.set()

    threading.Thread(target=_bg, daemon=True, name="daemon-kick").start()


def _activate_swap() -> None:
    """If the host attached a dedicated swap block device (per
    `NEEDS_SWAP` in playground/server/systems.py), mkswap (idempotent)
    and swapon it before serving requests so the load script can rely
    on it. The swap disk is the last virtio-blk device, sized in the
    hundreds of GB, and ships with no filesystem header on first boot.

    Idempotent: a device that already has `TYPE=swap` (i.e. survived a
    snapshot/restore cycle) is just swapon'd again.
    """
    candidates: list[tuple[str, int, str]] = []
    for entry in sorted(Path("/sys/block").glob("vd*")):
        name = entry.name
        try:
            sectors = int((entry / "size").read_text().strip())
        except Exception:
            continue
        size_bytes = sectors * 512
        # Below ~100 GB it isn't the playground's swap drive.
        if size_bytes < 100 * (1 << 30):
            continue
        dev = f"/dev/{name}"
        r = subprocess.run(
            ["blkid", "-s", "TYPE", "-o", "value", dev],
            capture_output=True, text=True,
        )
        fstype = r.stdout.strip()
        candidates.append((dev, size_bytes, fstype))
    # Prefer an already-mkswap'd device; otherwise pick the first empty one.
    target = next((d for d, _, t in candidates if t == "swap"), None)
    if target is None:
        target = next((d for d, _, t in candidates if t == ""), None)
        if target is None:
            return
        rc = subprocess.run(["mkswap", "-L", "cbswap", target]).returncode
        if rc != 0:
            print(f"agent: mkswap {target} rc={rc}", flush=True)
            return
    rc = subprocess.run(["swapon", target]).returncode
    print(f"agent: swapon {target} rc={rc}", flush=True)


def main() -> None:
    addr = ("0.0.0.0", LISTEN_PORT)
    print(f"agent: system={SYSTEM_NAME} listen={addr[0]}:{addr[1]} "
          f"dir={SYSTEM_DIR} data={DATASETS_DIR}", flush=True)
    _activate_swap()
    _reconcile_docker_after_restore()
    _kick_daemon_if_provisioned()
    with ReusableServer(addr, Handler) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    main()
