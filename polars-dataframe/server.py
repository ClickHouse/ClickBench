#!/usr/bin/env python3
"""FastAPI wrapper around polars so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, fixes
                        column types, holds the LazyFrame in memory, and
                        returns {"elapsed": <seconds>}
    POST /query      -> body: a Python expression. eval()s it against the
                        loaded LazyFrame (`hits`, `pl`, and `date` in scope)
                        and returns {"elapsed": <seconds>}.
    GET  /data-size  -> bytes the DataFrame currently occupies (estimated_size)

The /query endpoint takes a Python expression directly rather than an SQL
string mapped to a hardcoded lambda. Workload lives in queries.py
(line-by-line expressions). queries.sql is kept for cross-system reference.
"""

import os
import timeit
from datetime import date

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request

# Streaming engine will be the default soon.
pl.Config.set_engine_affinity("streaming")

app = FastAPI()
hits_df: pl.DataFrame | None = None
hits: pl.LazyFrame | None = None


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits, hits_df
    start = timeit.default_timer()
    df = pl.scan_parquet("hits.parquet").collect()
    df = df.with_columns(
        (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
        pl.col("EventDate").cast(pl.Date),
    )
    df = df.rechunk()
    hits_df = df
    hits = df.lazy()
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.post("/query")
async def query(request: Request):
    if hits is None:
        raise HTTPException(status_code=409, detail="DataFrame not loaded; POST /load first")
    code = (await request.body()).decode("utf-8").strip()
    if not code:
        raise HTTPException(status_code=400, detail="empty query")
    try:
        compiled = compile(code, "<query>", "eval")
    except SyntaxError as e:
        raise HTTPException(status_code=400, detail=f"syntax error: {e}")
    start = timeit.default_timer()
    eval(compiled, {"hits": hits, "pl": pl, "date": date})
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.get("/data-size")
def data_size():
    if hits_df is None:
        return {"bytes": 0}
    return {"bytes": int(hits_df.estimated_size())}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_POLARS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
