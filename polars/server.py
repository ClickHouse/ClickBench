#!/usr/bin/env python3
"""FastAPI wrapper around polars so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> builds a LazyFrame over hits.parquet (no
                        collect()) and returns {"elapsed": <seconds>}
    POST /query      -> body: a Python expression. eval()s it against the
                        loaded LazyFrame (`hits`, `pl`, and `date` in scope)
                        and returns {"elapsed": <seconds>}.
    GET  /data-size  -> on-disk parquet size (the LazyFrame is not
                        materialized so estimated_size doesn't apply)

The /query endpoint takes a Python expression directly rather than an
SQL string mapped to a hardcoded lambda. The workload lives in
queries.sql, one Python expression per line (the filename matches the
cross-system convention; the contents are not SQL).
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
hits: pl.LazyFrame | None = None
parquet_path: str = "hits.parquet"


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    # Lazy: just builds the plan. Data is read on each query collect().
    hits = pl.scan_parquet(parquet_path).with_columns(
        (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
        pl.col("EventDate").cast(pl.Date),
    )
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
    # LazyFrame doesn't materialize; report on-disk parquet size.
    try:
        return {"bytes": os.path.getsize(parquet_path)}
    except OSError:
        return {"bytes": 0}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_POLARS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
