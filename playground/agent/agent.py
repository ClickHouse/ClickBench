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

Listens on 0.0.0.0:8080 by default.

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
DATASETS_DIR = Path(os.environ.get("CLICKBENCH_DATASETS_DIR", "/opt/clickbench/datasets"))
STATE_DIR = Path(os.environ.get("CLICKBENCH_AGENT_STATE", "/var/lib/clickbench-agent"))
SYSTEM_NAME = (
    os.environ.get("CLICKBENCH_SYSTEM_NAME")
    or (Path("/etc/clickbench-system").read_text().strip()
        if Path("/etc/clickbench-system").exists() else SYSTEM_DIR.name)
)
LISTEN_PORT = int(os.environ.get("CLICKBENCH_AGENT_PORT", "8080"))
# 10 KB cap, matching the spec. Configurable for testing.
OUTPUT_LIMIT = int(os.environ.get("CLICKBENCH_OUTPUT_LIMIT", "10240"))
# Per-query wall-clock cap so a runaway query can't tie up a VM forever.
QUERY_TIMEOUT = int(os.environ.get("CLICKBENCH_QUERY_TIMEOUT", "600"))
# Provision (install/start/load) can legitimately take an hour for some systems.
PROVISION_TIMEOUT = int(os.environ.get("CLICKBENCH_PROVISION_TIMEOUT", "7200"))

STATE_DIR.mkdir(parents=True, exist_ok=True)
PROVISION_DONE = STATE_DIR / "provisioned"
PROVISION_LOG = STATE_DIR / "provision.log"

# Single-writer lock; the agent serializes queries per VM. Two ClickBench
# scripts hitting the same socket/temp file concurrently would not be safe.
_query_lock = threading.Lock()
_provision_lock = threading.Lock()


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


def _run_query(sql: bytes) -> tuple[int, bytes, bytes, float]:
    """
    Invoke ./query with the SQL on stdin.
    The query script's contract per lib/benchmark-common.sh:
      stdout: result (whatever format the system uses)
      stderr: timing in fractional seconds on the LAST numeric line
      exit code: 0 on success
    """
    script = _system_script("query")
    t0 = time.monotonic()
    try:
        p = subprocess.Popen(
            [str(script)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=str(SYSTEM_DIR),
            preexec_fn=os.setsid,
        )
        try:
            stdout, stderr = p.communicate(input=sql, timeout=QUERY_TIMEOUT)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            # The system might still be inside its query; kill the whole group.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(p.pid, signal.SIGKILL)
            stdout, stderr = p.communicate()
            rc = -9
    except Exception as e:
        return 255, b"", f"agent: failed to invoke ./query: {e}\n".encode(), 0.0
    return rc, stdout, stderr, time.monotonic() - t0


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
        while time.monotonic() - t0 < 300:
            last_check = subprocess.run(
                [str(check)], cwd=str(SYSTEM_DIR),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            if last_check.returncode == 0:
                ok = True
                break
            time.sleep(1)
        if not ok:
            log_lines.append(b"\n=== check did not succeed within 300s ===\n")
            if last_check is not None:
                log_lines.append(last_check.stderr or b"")
            PROVISION_LOG.write_bytes(b"".join(log_lines))
            return 1, b"".join(log_lines)
        log_lines.append(b"\n=== check ok ===\n")

        # Data files are pre-staged on the per-system disk by the host-side
        # build-system-rootfs.sh, so the load script's relative references
        # (hits.parquet, hits.tsv, etc.) already resolve to local files it
        # can chown / mv / rm without worrying about a RO source mount.

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
        if self.path == "/stats":
            self._send_json(200, _stats_snapshot())
            return
        if self.path == "/provision-log":
            data = PROVISION_LOG.read_bytes() if PROVISION_LOG.exists() else b""
            self._send(200, data, {"Content-Type": "text/plain; charset=utf-8"})
            return
        self._send_json(404, {"error": "not found", "path": self.path})

    def do_POST(self) -> None:
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
            if rc != 0:
                # Surface a snippet of stderr so the client sees *something*.
                err_snip = err[-1024:].decode("utf-8", errors="replace")
                headers["X-Error"] = err_snip.replace("\n", " | ")[:512]
            self._send(200 if rc == 0 else 502, body, headers)
            return
        self._send_json(404, {"error": "not found", "path": self.path})


class ReusableServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    addr = ("0.0.0.0", LISTEN_PORT)
    print(f"agent: system={SYSTEM_NAME} listen={addr[0]}:{addr[1]} "
          f"dir={SYSTEM_DIR} data={DATASETS_DIR}", flush=True)
    with ReusableServer(addr, Handler) as srv:
        srv.serve_forever()


if __name__ == "__main__":
    main()
