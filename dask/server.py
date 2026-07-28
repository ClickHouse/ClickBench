#!/usr/bin/env python3
"""FastAPI wrapper around Dask so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Dask is "pandas in parallel": its DataFrame mirrors the pandas API but
splits the data into partitions and runs across a local cluster of worker
processes. We therefore mirror the pandas port closely — queries.sql holds
Python expressions, one per line — and only diverge where Dask's API does:
operations are lazy, so the server materialises the result with
dask.compute() and rolls that into the query timing.

Routes:
    GET  /health     -> 200 OK once the cluster is up
    POST /load       -> reads hits_*.parquet from the working directory, fixes
                        column types, persists the DataFrame in cluster memory,
                        and returns {"elapsed": <seconds>}
    POST /query      -> body: a Python expression. eval()s it against the
                        loaded DataFrame (`hits`, `dd`, `dask`, `pd`, and the
                        `nunique` aggregation in scope), forces computation
                        with dask.compute(), and returns {"elapsed": <secs>}.
    GET  /data-size  -> bytes the DataFrame occupies in memory (memory_usage)

The /query endpoint takes a Python expression directly rather than an SQL
string mapped to a hardcoded lambda. The workload lives in queries.sql,
one Python expression per line (the filename matches the cross-system
convention; the contents are not SQL).
"""

import os
import timeit
from contextlib import asynccontextmanager

import dask
import dask.dataframe as dd
import pandas as pd
import uvicorn
from dask.distributed import Client, LocalCluster, wait
from fastapi import FastAPI, HTTPException, Request

# Dask's built-in groupby.agg() doesn't offer nunique, so COUNT(DISTINCT)
# combined with other aggregates in one pass (queries 10 and 23) needs the
# documented custom aggregation. Exposed in the query scope as `nunique`.
# https://docs.dask.org/en/stable/dataframe-groupby.html#aggregate
nunique = dd.Aggregation(
    name="nunique",
    chunk=lambda s: s.apply(lambda x: list(set(x))),
    agg=lambda s0: s0.obj.groupby(level=list(range(s0.obj.index.nlevels))).sum(),
    finalize=lambda s1: s1.apply(lambda final: len(set(final))),
)

# Dask reads a directory of parquet files as one partition per file, which
# is the natural, idiomatic layout for it — so we use the partitioned
# dataset (hits_0.parquet … hits_99.parquet). Resolve to an absolute glob so
# the read doesn't depend on the worker processes' CWD.
PARQUET_GLOB = os.environ.get(
    "BENCH_DASK_PARQUET",
    os.path.abspath("hits_*.parquet"),
)

client: Client | None = None
cluster: LocalCluster | None = None
hits = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    # The benchmark harness stops+starts this server before every cold
    # query (BENCH_DURABLE=no). Tear the cluster down on shutdown so its
    # worker processes don't orphan and pile up across the ~40 restarts.
    if client is not None:
        client.close()
    if cluster is not None:
        cluster.close()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    # Only healthy once the cluster is actually up.
    return {"ok": client is not None}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    df = dd.read_parquet(PARQUET_GLOB)
    # Match the pandas port's type fixups: epoch-seconds -> datetime and
    # epoch-days -> datetime. Dask already reads string columns as compact
    # pyarrow-backed `string` dtype, so no object->str pass is needed.
    df["EventTime"] = dd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = dd.to_datetime(df["EventDate"], unit="D")
    # Hold the whole frame in cluster memory (the pandas/polars in-memory
    # model) and block until every partition has actually materialised, so
    # the reported load time is honest.
    hits = df.persist()
    wait(hits)
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
    scope = {"hits": hits, "dd": dd, "dask": dask, "pd": pd, "nunique": nunique}
    start = timeit.default_timer()
    # eval() builds the (lazy) Dask graph; dask.compute() runs it. Timing
    # both mirrors the pandas port, where eval() itself does all the work.
    # dask.compute() recurses into tuples/lists, so queries that return a
    # tuple of scalars (3, 7) or a list of sums (30) compute in one pass.
    result = dask.compute(eval(compiled, scope))[0]
    elapsed = round(timeit.default_timer() - start, 3)
    # Render the result as a string so the playground UI sees the actual
    # query output instead of just the timing. Truncated by the agent
    # to OUTPUT_LIMIT before it reaches the browser.
    return {"elapsed": elapsed, "result": str(result)}


@app.get("/data-size")
def data_size():
    if hits is None:
        return {"bytes": 0}
    return {"bytes": int(hits.memory_usage(deep=True).sum().compute())}


if __name__ == "__main__":
    # A local cluster of worker processes gives Dask real multi-core
    # parallelism. Defaults pick a sensible worker/thread split for the
    # machine; the dashboard is disabled so the benchmark doesn't bind an
    # extra port. Created here (guarded by __main__ so spawned workers
    # don't re-run it) before uvicorn serves, so /health only answers
    # once the cluster is ready.
    cluster = LocalCluster(dashboard_address=None)
    client = Client(cluster)
    port = int(os.environ.get("BENCH_DASK_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
