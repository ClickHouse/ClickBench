#!/usr/bin/env python3
"""FastAPI wrapper around Krishiv (embedded, in-process) so that it conforms
to the ClickBench install/start/check/stop/load/query interface. One Krishiv
session lives for the whole run, as an application embedding it would.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> registers hits.parquet as the `hits` view with the
                        EventTime/EventDate casts, returns {"elapsed": ...}
    POST /query      -> body: SQL text. Runs it with session.sql and
                        materializes the full result as an Arrow table,
                        returns {"elapsed": <seconds>, "result": <TSV text>}
    GET  /data-size  -> size of hits.parquet
"""

import glob
import os
import timeit

import krishiv
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.concurrency import run_in_threadpool

app = FastAPI()
session = krishiv.session()
# The partitioned files store strings as BINARY, as in Spark.
session.conf.set("spark.sql.parquet.binaryAsString", "true")
data_bytes = 0

PARQUET = os.path.abspath(os.environ.get("BENCH_KRISHIV_PARQUET", "hits.parquet"))


def parquet_bytes() -> int:
    return sum(os.path.getsize(p) for p in glob.glob(PARQUET))


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global data_bytes
    start = timeit.default_timer()
    data_bytes = parquet_bytes()
    session.read.parquet(PARQUET).createOrReplaceTempView("hits_raw")
    # EventTime is stored as Unix seconds and EventDate as days since the
    # epoch; expose them as TIMESTAMP and DATE, keeping the column order.
    exprs = {
        "EventTime": "timestamp_seconds(EventTime) AS EventTime",
        "EventDate": "date_from_unix_date(EventDate) AS EventDate",
    }
    select = ", ".join(exprs.get(c, c) for c in session.table("hits_raw").columns)
    session.sql(f"CREATE OR REPLACE TEMPORARY VIEW hits AS SELECT {select} FROM hits_raw")
    return {"elapsed": round(timeit.default_timer() - start, 3)}


@app.post("/query")
async def query(request: Request):
    if not data_bytes:
        raise HTTPException(status_code=409, detail="not loaded; POST /load first")
    sql = (await request.body()).decode("utf-8").strip().rstrip(";")
    if not sql:
        raise HTTPException(status_code=400, detail="empty query")
    return await run_in_threadpool(run_query, sql)


def run_query(sql: str):
    start = timeit.default_timer()
    try:
        # The full result is materialized inside the timed region.
        result = session.sql(sql).toArrow()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    elapsed = round(timeit.default_timer() - start, 3)
    text = "\n".join("\t".join(map(str, row.values())) for row in result.to_pylist())
    return {"elapsed": elapsed, "result": text}


@app.get("/data-size")
def data_size():
    return {"bytes": data_bytes or parquet_bytes()}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_KRISHIV_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
