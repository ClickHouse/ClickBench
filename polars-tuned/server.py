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

import gc
import multiprocessing
import os
import timeit
import warnings
from datetime import date

warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)
gc.enable()

# ====================================================
# HARDWARE THREAD DETECTOR (Constant at startup)
# ====================================================
total_cores = multiprocessing.cpu_count()
if total_cores >= 64:
    # Server profile (e.g., c6a.metal - up to 96 threads)
    TARGET_THREADS = min(total_cores, 96)
else:
    # Local profile
    TARGET_THREADS = min(total_cores, 16)

os.environ.setdefault("POLARS_MAX_THREADS", str(TARGET_THREADS))
os.environ.setdefault("POLARS_ACTIVATE_DECIMAL", "0")

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request

# Enable global string cache and streaming engine affinity
pl.enable_string_cache()
if hasattr(pl, "set_thread_pool_size"):
    pl.set_thread_pool_size(TARGET_THREADS)
pl.Config.set_engine_affinity("streaming")

# ClickBench timings must include serializing the full query result back
# to the client (README, "Output Suppression"), so render tables without
# any row/column/cell truncation — nothing may be suppressed.
pl.Config.set_tbl_rows(-1)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_width_chars(-1)
pl.Config.set_fmt_str_lengths(65535)

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
    # Lazy: builds the optimized execution plan with compact bit-width types
    # for better CPU L2/L3 cache locality while preserving cold-run rules.
    hits = pl.scan_parquet(parquet_path, low_memory=False).with_columns(
        (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
        pl.col("EventDate").cast(pl.Date),
        pl.col("SearchPhrase").cast(pl.Categorical),
        pl.col("Title").cast(pl.String),
        pl.col("URL").cast(pl.String),
        pl.col("AdvEngineID").cast(pl.Int16),
        pl.col("ResolutionWidth").cast(pl.Int32),
        pl.col("ResolutionHeight").cast(pl.Int32),
        pl.col("RegionID").cast(pl.Int32),
        pl.col("IsMobile").cast(pl.Int8),
        pl.col("SearchEngineID").cast(pl.Int16),
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
    value = eval(compiled, {"hits": hits, "pl": pl, "date": date})
    # Rendering the result is part of the timed run: ClickBench measures
    # back-to-back runtimes including returning the result to the client
    # (issue #1397). polars DataFrames / Series / LazyFrames have a useful
    # __str__; everything else (scalar, tuple, dict, ...) falls through
    # repr.
    if isinstance(value, (pl.DataFrame, pl.Series, pl.LazyFrame)):
        result = str(value)
    else:
        result = repr(value)
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "result": result}


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
