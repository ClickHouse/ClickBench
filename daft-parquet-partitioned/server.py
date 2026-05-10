#!/usr/bin/env python3
"""FastAPI wrapper around Daft (partitioned parquet) so it conforms to the
ClickBench install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits_*.parquet from the working directory, casts
                        types, holds the Daft DataFrame in memory, registers
                        it as `hits` for daft.sql, returns {"elapsed": ...}
    POST /query      -> body: SQL text. Runs it via daft.sql against the
                        registered `hits` view, returns {"elapsed": <seconds>}.
    GET  /data-size  -> total file size of hits_*.parquet at load time.

"""

import os
import timeit

import daft
import uvicorn
from daft import DataType, col
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits = None
data_bytes = 0

PARQUET_GLOB = os.environ.get("BENCH_DAFT_PARQUET", "hits_*.parquet")


def _data_size_bytes() -> int:
    import glob
    total = 0
    for p in glob.glob(PARQUET_GLOB):
        try:
            total += os.path.getsize(p)
        except OSError:
            pass
    return total


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits, data_bytes
    start = timeit.default_timer()
    data_bytes = _data_size_bytes()
    df = daft.read_parquet(PARQUET_GLOB)
    df = df.with_column("EventTime", col("EventTime").cast(DataType.timestamp("s")))
    df = df.with_column("EventDate", col("EventDate").cast(DataType.date()))
    df = df.with_column("URL", col("URL").decode("utf-8"))
    df = df.with_column("Title", col("Title").decode("utf-8"))
    df = df.with_column("Referer", col("Referer").decode("utf-8"))
    df = df.with_column("MobilePhoneModel", col("MobilePhoneModel").decode("utf-8"))
    df = df.with_column("SearchPhrase", col("SearchPhrase").decode("utf-8"))
    hits = df
    # Register so daft.sql can see `hits`.
    try:
        daft.catalog.register_table("hits", df)  # type: ignore[attr-defined]
    except Exception:
        pass
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.post("/query")
async def query(request: Request):
    if hits is None:
        raise HTTPException(status_code=409, detail="DataFrame not loaded; POST /load first")
    sql = (await request.body()).decode("utf-8").strip()
    if not sql:
        raise HTTPException(status_code=400, detail="empty query")
    start = timeit.default_timer()
    daft.sql(sql).collect()
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.get("/data-size")
def data_size():
    if data_bytes:
        return {"bytes": int(data_bytes)}
    # Fall back to the on-disk size if /load hasn't run yet.
    return {"bytes": _data_size_bytes()}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_DAFT_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
