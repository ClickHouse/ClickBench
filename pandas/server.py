#!/usr/bin/env python3
"""FastAPI wrapper around pandas so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, fixes
                        column types, holds the DataFrame in memory, and
                        returns {"elapsed": <seconds>}
    POST /query      -> body: a Python expression. eval()s it against the
                        loaded DataFrame (`hits` and `pd` in scope) and
                        returns {"elapsed": <seconds>}.
    GET  /data-size  -> bytes the DataFrame currently occupies (memory_usage)

The /query endpoint takes a Python expression directly rather than an SQL
string mapped to a hardcoded lambda. The workload lives in queries.sql,
one Python expression per line (the filename matches the cross-system
convention; the contents are not SQL).
"""

import os
import timeit

import pandas as pd
import uvicorn
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits: pd.DataFrame | None = None


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    df = pd.read_parquet("hits.parquet")
    df["EventTime"] = pd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = pd.to_datetime(df["EventDate"], unit="D")
    for col in df.columns:
        if df[col].dtype == "O":
            df[col] = df[col].astype(str)
    hits = df
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
    result = eval(compiled, {"hits": hits, "pd": pd})
    elapsed = round(timeit.default_timer() - start, 3)
    # Render the result as a string so the playground UI sees the actual
    # query output instead of just the timing. Truncated by the agent
    # to OUTPUT_LIMIT before it reaches the browser.
    return {"elapsed": elapsed, "result": str(result)}


@app.get("/data-size")
def data_size():
    if hits is None:
        return {"bytes": 0}
    return {"bytes": int(hits.memory_usage().sum())}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_PANDAS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
