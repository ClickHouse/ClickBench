#!/usr/bin/env python3
"""FastAPI wrapper around chDB so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, fixes
                        column types, holds the DataFrame in memory, and
                        returns {"elapsed": <seconds>}
    POST /query      -> body: SQL text. Runs it via chdb against the loaded
                        DataFrame (Python(hits) table function), returns
                        {"elapsed": <seconds>}.
    GET  /data-size  -> bytes the DataFrame currently occupies (memory_usage)
"""

import os
import timeit

import chdb
import pandas as pd
import uvicorn
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits: pd.DataFrame | None = None  # noqa: F841 — referenced by chdb's Python() table function
conn = None


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits, conn
    start = timeit.default_timer()
    df = pd.read_parquet("hits.parquet")
    df["EventTime"] = pd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = pd.to_datetime(df["EventDate"], unit="D")
    for col in df.columns:
        if df[col].dtype == "O":
            df[col] = df[col].astype(str)
    hits = df
    # chdb addresses `hits` via Python(hits); the connection picks up the
    # variable from the module globals at query time.
    conn = chdb.connect("./tmp")
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
    conn.query(sql, "Null")
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.get("/data-size")
def data_size():
    if hits is None:
        return {"bytes": 0}
    return {"bytes": int(hits.memory_usage().sum())}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_CHDB_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
