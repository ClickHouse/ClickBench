#!/usr/bin/env python3
"""FastAPI wrapper around the Polars SQL interface so it conforms to the
ClickBench install/start/check/stop/load/query interface.

Same as `polars-sql-parquet/`, but over the partitioned dataset
(hits_0.parquet ... hits_99.parquet) instead of the single hits.parquet.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> registers a LazyFrame over hits_*.parquet as the
                        `hits` table (no collect()) and returns
                        {"elapsed": <seconds>}
    POST /query      -> body: one SQL query. Executes it lazily, collects
                        the result and returns
                        {"elapsed": <seconds>, "result": "<rendered table>"}
    GET  /data-size  -> total on-disk size of hits_*.parquet (the LazyFrame
                        is not materialized so estimated_size doesn't apply)
"""

import glob
import os
import timeit

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request

# Same engine as `polars/`.
pl.Config.set_engine_affinity("streaming")

# ClickBench timings must include serializing the full query result back
# to the client (README, "Output Suppression"), so render tables without
# any row/column/cell truncation — nothing may be suppressed.
pl.Config.set_tbl_rows(-1)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_width_chars(-1)
pl.Config.set_fmt_str_lengths(65535)

app = FastAPI()
ctx: pl.SQLContext | None = None
parquet_glob: str = "hits_*.parquet"


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global ctx
    start = timeit.default_timer()
    # Lazy: just builds the plan. Data is read on each query collect().
    # The partitioned files store EventTime as Unix seconds and EventDate as
    # days since the epoch; expose them as Datetime / Date, so the queries
    # can use EXTRACT, DATE_TRUNC and date comparisons as written. They also
    # store strings as BYTE_ARRAY without a UTF8 annotation, so they are
    # read as Binary; cast them back to String.
    hits = pl.scan_parquet(parquet_glob).with_columns(
        pl.col(pl.Binary).cast(pl.String),
        (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
        pl.col("EventDate").cast(pl.Date),
    )
    ctx = pl.SQLContext(hits=hits)
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


# Build the lazy scan at startup. Nothing is read here, so this is
# equivalent to another engine registering a view over the Parquet data
# before its timer starts. With the plan built at startup, the entry can
# run as BENCH_DURABLE=yes: a restarted server can answer queries
# straight away, and the driver doesn't add ./load's wall time (curl,
# python3, sync) to each cold run.
load()


@app.post("/query")
async def query(request: Request):
    if ctx is None:
        raise HTTPException(status_code=409, detail="table not registered; POST /load first")
    sql = (await request.body()).decode("utf-8").strip()
    if not sql:
        raise HTTPException(status_code=400, detail="empty query")
    start = timeit.default_timer()
    try:
        # Rendering the result is part of the timed run: ClickBench
        # measures runtimes including returning the result to the client
        # (issue #1397).
        result = str(ctx.execute(sql).collect())
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"{type(e).__name__}: {e}")
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "result": result}


@app.get("/data-size")
def data_size():
    # LazyFrame doesn't materialize; report total on-disk parquet size.
    total = 0
    for path in glob.glob(parquet_glob):
        try:
            total += os.path.getsize(path)
        except OSError:
            pass
    return {"bytes": total}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_POLARS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
