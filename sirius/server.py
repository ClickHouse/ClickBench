#!/usr/bin/env python3
"""FastAPI wrapper around Sirius (GPU-accelerated DuckDB extension) so it
conforms to the ClickBench install/start/check/stop/load/query interface.

Sirius is a DuckDB extension built from source; queries run on the GPU via
``call gpu_processing("<sql>");``. This server manages a long-lived ``duckdb``
CLI subprocess so the GPU buffers initialised on /load remain hot across
queries.

Routes:
    GET  /health     -> 200 OK once the CLI subprocess is ready
    POST /load       -> opens hits.db, calls gpu_buffer_init, returns
                        {"elapsed": <seconds>}. (Schema/data are loaded by
                        ./load before this runs.)
    POST /query      -> body: SQL text. Looks it up in QUERIES, runs it via
                        gpu_processing, returns {"elapsed": <seconds>}.
    GET  /data-size  -> bytes of hits.db on disk.
"""

import os
import re
import subprocess
import threading
import timeit

import uvicorn
from fastapi import FastAPI, HTTPException, Request

GPU_CACHING_SIZE = os.environ.get("SIRIUS_GPU_CACHING_SIZE", "80 GB")
GPU_PROCESSING_SIZE = os.environ.get("SIRIUS_GPU_PROCESSING_SIZE", "40 GB")
CPU_PROCESSING_SIZE = os.environ.get("SIRIUS_CPU_PROCESSING_SIZE", "100 GB")

DB_PATH = os.environ.get("SIRIUS_DB", "hits.db")

app = FastAPI()
proc: subprocess.Popen | None = None
proc_lock = threading.Lock()
buffers_initialized = False

# Sentinel sent after each command to detect completion in stdout.
SENTINEL = "__SIRIUS_DONE__"


# Read query strings from queries.sql (canonical) on import. We expose the
# same shape as the pandas pilot — (sql, callable). The callable runs the
# SQL via gpu_processing on the persistent duckdb session.
def _load_query_strings() -> list[str]:
    here = os.path.dirname(os.path.abspath(__file__))
    qpath = os.path.join(here, "queries.sql")
    with open(qpath) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


_SQL_LIST = _load_query_strings()


def _make_runner(sql: str):
    return lambda: _run_gpu(sql)


QUERIES: list[tuple[str, callable]] = [(sql, _make_runner(sql)) for sql in _SQL_LIST]
QUERY_INDEX = {sql: i for i, (sql, _) in enumerate(QUERIES)}


def _spawn_duckdb() -> subprocess.Popen:
    # Open a persistent duckdb CLI session against hits.db. The Sirius build
    # places the duckdb binary on PATH (see install).
    return subprocess.Popen(
        ["duckdb", DB_PATH],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def _send(cmd: str) -> str:
    """Send a SQL/CLI command to duckdb and read until the sentinel. Returns
    the raw output (excluding the sentinel line)."""
    assert proc is not None and proc.stdin is not None and proc.stdout is not None
    with proc_lock:
        proc.stdin.write(cmd.rstrip(";") + ";\n")
        proc.stdin.write(f"select '{SENTINEL}';\n")
        proc.stdin.flush()
        out_lines: list[str] = []
        while True:
            line = proc.stdout.readline()
            if not line:
                raise RuntimeError("duckdb subprocess closed unexpectedly")
            if SENTINEL in line:
                # Drain the trailing border row from the boxed select output.
                # DuckDB emits the table for `select '...'` as several lines;
                # readline on the SENTINEL line is enough — subsequent lines
                # belong to the next command.
                break
            out_lines.append(line)
        return "".join(out_lines)


def _run_gpu(sql: str) -> str:
    # Wrap user SQL inside gpu_processing("..."); escape embedded double quotes.
    escaped = sql.replace('"', '\\"')
    return _send(f'call gpu_processing("{escaped}")')


@app.get("/health")
def health():
    if proc is None or proc.poll() is not None:
        raise HTTPException(status_code=503, detail="duckdb subprocess not running")
    return {"ok": True}


@app.on_event("startup")
def _startup():
    global proc
    proc = _spawn_duckdb()
    # Quiet down the CLI a bit.
    _send(".mode list")


@app.on_event("shutdown")
def _shutdown():
    global proc
    if proc is not None:
        try:
            proc.stdin.write(".quit\n")
            proc.stdin.flush()
        except Exception:
            pass
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        proc = None


@app.post("/load")
def load():
    """For Sirius the on-disk DuckDB database is created by the ``./load``
    script (which runs create.sql + load.sql). Here we just initialise the
    GPU buffers on the persistent connection so subsequent queries are warm.
    """
    global buffers_initialized
    start = timeit.default_timer()
    if not buffers_initialized:
        _send(
            f'call gpu_buffer_init("{GPU_CACHING_SIZE}", "{GPU_PROCESSING_SIZE}", '
            f'pinned_memory_size = "{CPU_PROCESSING_SIZE}")'
        )
        buffers_initialized = True
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.post("/query")
async def query(request: Request):
    body = (await request.body()).decode("utf-8").strip()
    idx = QUERY_INDEX.get(body)
    if idx is None:
        raise HTTPException(status_code=404, detail=f"unknown query: {body[:120]}")
    sql = QUERIES[idx][0]
    start = timeit.default_timer()
    out = _run_gpu(sql)
    elapsed = round(timeit.default_timer() - start, 3)
    # If duckdb reports an error, surface it.
    if re.search(r"\bError\b", out):
        raise HTTPException(status_code=500, detail=out.strip()[:500])
    return {"elapsed": elapsed, "index": idx}


@app.get("/data-size")
def data_size():
    try:
        return {"bytes": int(os.path.getsize(DB_PATH))}
    except OSError:
        return {"bytes": 0}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_SIRIUS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
