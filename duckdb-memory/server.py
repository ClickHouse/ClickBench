#!/usr/bin/env python3
"""FastAPI wrapper around DuckDB's compressed in-memory storage so it
conforms to the ClickBench install/start/check/stop/load/query interface.

Each /query runs against a long-lived DuckDB connection that holds the
hits table in compressed memory, so we don't pay re-load cost per query
(which is what made the previous "embedded Python per query" version
unusable — every query was measuring full parquet ingestion time).

Routes:
    GET  /health    -> 200 OK once the server is up.
    POST /load      -> reads hits.parquet from CWD into the
                       compressed_mem :memory: schema. Returns
                       {"elapsed": <seconds>}.
    POST /query     -> body: SQL text. Runs against the loaded table.
                       Returns {"elapsed": <seconds>}.
    GET  /data-size -> returns process RSS in bytes (proxy for the
                       in-memory compressed footprint).
"""

import os
import resource
import timeit

import duckdb
import psutil
import uvicorn
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
conn: duckdb.DuckDBPyConnection | None = None


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global conn
    start = timeit.default_timer()
    conn = duckdb.connect()
    # preserve_insertion_order=false lets the loader use a cheaper insert
    # path. create.sql does its own `ATTACH ':memory:' AS compressed_mem
    # (COMPRESS); USE compressed_mem;` to set up the compressed in-memory
    # database that's the whole point of this entry vs. plain duckdb.
    conn.execute("SET preserve_insertion_order = false;")
    conn.execute(open("create.sql").read())
    conn.execute(open("load.sql").read())
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.post("/query")
async def query(request: Request):
    if conn is None:
        raise HTTPException(status_code=409, detail="hits not loaded; POST /load first")
    sql = (await request.body()).decode("utf-8").strip()
    if not sql:
        raise HTTPException(status_code=400, detail="empty query")
    start = timeit.default_timer()
    conn.execute(sql).fetchall()
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.get("/data-size")
def data_size():
    # DuckDB's compressed_mem has no on-disk footprint, so report the
    # server process RSS (peak so far). This mirrors what the previous
    # memory.py + `time -v` did, and matches what clickbench
    # convention expects (an integer byte count).
    rss = psutil.Process().memory_info().rss
    # Also check resource.getrusage — on Linux ru_maxrss is in kB and
    # tracks the high-water mark across the process lifetime.
    peak_kb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    peak = peak_kb * 1024
    return {"bytes": max(rss, peak)}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_DUCKDB_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
