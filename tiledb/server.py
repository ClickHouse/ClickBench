#!/usr/bin/env python3
"""FastAPI wrapper around TileDB so that it conforms to the ClickBench
install/start/check/stop/load/query interface.

TileDB is an embedded array storage engine: a C++ library with a Python
API, without a server process and without a query language. So the wrapper
looks like the other dataframe ports (pandas, dask, polars-dataframe,
arcticdb): queries.sql holds one Python expression per line, which this
server eval()s. The data is not in the memory of the process: it is in a
TileDB array on disk (written by load.py), which survives a restart, so
benchmark.sh leaves BENCH_DURABLE at its default "yes".

Routes:
    GET  /health  -> 200 OK
    POST /query   -> body: a Python expression. eval()s it and returns
                     {"elapsed": <seconds>, "result": <rendered result>}

The names in scope for a query are documented on QUERY_SCOPE below.
"""

import os
import threading
import timeit

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import tiledb
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from starlette.concurrency import run_in_threadpool

ARRAY = os.path.abspath(os.environ.get("BENCH_TILEDB_ARRAY", "hits_array"))

# A TileDB read fills buffers that the caller provides, and returns as many
# cells as fit ("incomplete query"); the caller takes them and submits the
# query again for the next batch. This is the size of the buffer of every
# field in a batch: TileDB itself has no default for it, and the one of
# TileDB-Py, 10 MB, makes a scan of a long string column two to three
# times slower than 64 MB does.
BATCH_BYTES = int(os.environ.get("BENCH_TILEDB_BATCH_BYTES", str(64 * 1024 * 1024)))

# The whole array: no restriction on either dimension.
ALL = slice(None)

_array = None
_array_lock = threading.Lock()


def hits():
    """The array, opened for reading on first use and kept open.

    An open array caches the fragment metadata (tile offsets, the R-trees
    over the dimensions) that the queries load, which is what a hot run
    keeps and a cold run does not have.
    """
    global _array
    with _array_lock:
        if _array is None:
            ctx = tiledb.Ctx({"py.init_buffer_bytes": str(BATCH_BYTES)})
            _array = tiledb.open(ARRAY, ctx=ctx)
        return _array


def read(attrs=(), dims=(), cond=None, at=ALL, each=None):
    """The cells of the slice `at` that satisfy `cond`, as an Arrow table.

    attrs  the attributes to read; None for all of them
    dims   the dimensions to return as columns (CounterID, EventDate)
    cond   a TileDB query condition, evaluated by the engine: comparisons
           of an attribute or a dimension with a constant, joined with
           `and` / `or`. It may refer to attributes that are not read.
    at     a slice of the dimensions, (CounterID, EventDate), with
           inclusive bounds; TileDB reads only the data tiles whose
           bounding rectangles intersect it.
    each   a function applied to every batch of the result as it arrives:
           for what TileDB cannot evaluate (a substring search, the length
           of a string), so that the columns it needs are not accumulated
           for the whole table.
    """
    array = hits()
    if attrs is None:
        attrs = [array.schema.attr(i).name for i in range(array.schema.nattr)]
    query = array.query(
        attrs=list(attrs),
        dims=list(dims) or False,
        cond=cond,
        index_col=False,
        return_arrow=True,
        return_incomplete=True,
    )
    batches = []
    for batch in query.df[at]:
        batches.append(batch if each is None else each(batch))
    return pa.concat_tables(batches)


def agg(spec, cond=None, at=ALL):
    """Aggregates computed inside TileDB, without returning the cells.

    spec is {attribute: operation or list of operations}; the operations
    are count, sum, mean, min, max. There is no grouping.
    """
    return hits().query(cond=cond).agg(spec)[at]


def count(cond=None, at=ALL):
    """The number of cells of the slice `at` that satisfy `cond`.

    TileDB-Py attaches every aggregate to an attribute, including the
    count, which does not depend on it.
    """
    return agg({hits().schema.attr(0).name: "count"}, cond, at)


def fetch(keys):
    """Whole rows for the cells listed in `keys`.

    `keys` is a table with the columns CounterID, EventDate and WatchID.
    The cells are located through the dimensions, by their coordinates,
    and the condition on WatchID picks them among the cells that share
    these coordinates. This is the second step of a query that has to
    choose its rows outside of TileDB (LIKE, ORDER BY ... LIMIT) and
    return all of their columns.
    """
    counters = sorted(set(keys["CounterID"].to_pylist()))
    dates = sorted(set(keys["EventDate"].to_pylist()))
    watch_ids = sorted(set(keys["WatchID"].to_pylist()))
    if not watch_ids:
        return keys
    return read(
        None,
        dims=("CounterID", "EventDate"),
        cond=" or ".join(f"WatchID == {watch_id}" for watch_id in watch_ids),
        at=(counters, [np.datetime64(date, "D") for date in dates]),
    )


def group(table, keys, aggregations):
    """GROUP BY `keys` on an Arrow table.

    `aggregations` are (column, function) pairs as in Table.group_by, e.g.
    ("UserID", "count_distinct"); COUNT stands for COUNT(*).

    The aggregation runs on the calling thread, not on the thread pool of
    Arrow, which is the default: see README.md. In short, the pool took a
    third more memory for the keys of high cardinality without being
    faster, and the wrapper was seen to die of a segmentation fault in
    one of its threads.
    """
    return table.group_by(keys, use_threads=False).aggregate(aggregations)


def top(table, by, n=10, offset=0, order="descending"):
    """ORDER BY `by` LIMIT `n` OFFSET `offset` on an Arrow table.

    `by` is a column name, or a list of (column, order) pairs.
    """
    keys = [(by, order)] if isinstance(by, str) else by
    indices = pc.select_k_unstable(table, k=offset + n, sort_keys=keys)
    return table.take(indices).slice(offset, n)


def days(first, last):
    """An inclusive range of the EventDate dimension."""
    return slice(np.datetime64(first, "D"), np.datetime64(last, "D"))


def let(value, fn):
    """Bind an intermediate result inside a single expression.

    queries.sql holds one Python *expression* per line, and some of the
    queries need the same table twice (to derive a column from it and then
    to group it).
    """
    return fn(value)


# Names visible to a query expression. The first group is TileDB; the rest
# is what works on its results.
QUERY_SCOPE = {
    "hits": hits,
    "read": read,
    "agg": agg,
    "count": count,
    "fetch": fetch,
    "days": days,
    "ALL": ALL,
    "group": group,
    "top": top,
    "let": let,
    # COUNT(*) among the aggregations of group()
    "COUNT": ([], "count_all"),
    "pa": pa,
    "pc": pc,
    "np": np,
}

app = FastAPI()


@app.get("/health")
def health():
    return {"ok": True}


def render(value):
    """The whole result as text: nothing may be truncated."""
    if isinstance(value, pa.Table):
        return value.to_pandas().to_string(index=False)
    if isinstance(value, pa.Scalar):
        return str(value.as_py())
    return str(value)


def _query(compiled):
    start = timeit.default_timer()
    value = eval(compiled, dict(QUERY_SCOPE))
    # Rendering the result is part of the timed run: ClickBench measures
    # back-to-back runtimes including returning the result to the client.
    result = render(value)
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "result": result}


@app.post("/query")
async def query(request: Request):
    code = (await request.body()).decode("utf-8").strip()
    if not code:
        raise HTTPException(status_code=400, detail="empty query")
    try:
        compiled = compile(code, "<query>", "eval")
    except SyntaxError as e:
        raise HTTPException(status_code=400, detail=f"syntax error: {e}")
    if tiledb.object_type(ARRAY) != "array":
        raise HTTPException(status_code=409, detail="hits is not loaded; run ./load first")
    # Off the event loop: a query can run for minutes, and the concurrent-QPS
    # watchdog polls /health every 5 s. Blocking the loop would make it
    # conclude that the server had died and restart it in the middle.
    try:
        return await run_in_threadpool(_query, compiled)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"{type(e).__name__}: {e}")


if __name__ == "__main__":
    # Open the array at startup when it is already loaded, so that the
    # startup time includes it.
    if tiledb.object_type(ARRAY) == "array":
        hits()
    port = int(os.environ.get("BENCH_TILEDB_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
