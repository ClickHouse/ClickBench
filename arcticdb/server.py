#!/usr/bin/env python3
"""FastAPI wrapper around ArcticDB so it conforms to the ClickBench
install/start/check/stop/load/query interface.

ArcticDB is an embedded, versioned DataFrame store: a C++ engine with a
Python API and no SQL, no query language, and no server process. So the
wrapper looks like the other dataframe ports (pandas, dask,
polars-dataframe) — queries.sql holds one Python expression per line,
which this server eval()s — but the data itself is not in process memory:
it lives in an on-disk LMDB store that survives a restart, which is why
benchmark.sh leaves BENCH_DURABLE at its default "yes".

Routes:
    GET  /health     -> 200 OK once the store is open
    POST /load       -> streams hits.parquet from the working directory into
                        the `hits` symbol and returns {"elapsed": <seconds>}
    POST /query      -> body: a Python expression. eval()s it against the
                        library and returns {"elapsed": <secs>, "result": ...}
    GET  /data-size  -> allocated bytes of the LMDB store on disk

The names in scope for a query are documented on QUERY_SCOPE below.
"""

import os
import re
import timeit

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from starlette.concurrency import run_in_threadpool

import arcticdb as adb
from arcticdb import Arctic, LibraryOptions, QueryBuilder

# ClickBench timings must include serializing the full query result back
# to the client (README, "Output Suppression"), so render frames without
# any row/column/cell truncation — nothing may be suppressed.
pd.set_option("display.max_rows", None)
pd.set_option("display.max_columns", None)
pd.set_option("display.width", None)
pd.set_option("display.max_colwidth", None)

STORE = os.path.abspath(os.environ.get("BENCH_ARCTICDB_STORE", "store"))
LIBRARY = "clickbench"
SYMBOL = "hits"
PARQUET = os.environ.get("BENCH_ARCTICDB_PARQUET", "hits.parquet")

# Rows per `append`. The whole DataFrame handed to write/append has to fit
# in RAM (ArcticDB normalizes it to a single frame before slicing it into
# segments), and hits is ~1 kB/row once it is Python objects and datetimes,
# so 1M rows is ~1 GB per chunk, ~2 GB counting the arrow side.
#
# The lower bound on the chunk size is the symbol's index key: every append
# writes a fresh one listing every segment in the symbol so far, so the
# bytes it costs grow with the square of the number of appends. Following
# hits.parquet's own row groups (226 of them, ~440k rows each) would mean
# 226 appends; buffering up to CHUNK_ROWS first brings that down to ~100.
CHUNK_ROWS = int(os.environ.get("BENCH_ARCTICDB_CHUNK_ROWS", "1000000"))

# The athena-compatible hits.parquet stores the time columns as raw
# integers (seconds since epoch for the timestamps, days since epoch for
# the date) rather than as parquet logical types, so they have to be
# converted on the way in — ArcticDB filters and resamples on real
# datetime64 columns, and `EventDate >= '2013-07-01'` in the workload is a
# timestamp comparison.
SECONDS_COLUMNS = ("EventTime", "ClientEventTime", "LocalEventTime")
DAYS_COLUMNS = ("EventDate",)

# A ceiling, not an allocation: LMDB reserves this much virtual address
# space and grows data.mdb into it on demand — a 40 GB map over 250 MB of
# data leaves a 250 MB file. Exceeding it is what fails, with MDB_MAP_FULL.
# ArcticDB's own Linux default is 400 GiB; state it explicitly so the store
# doesn't depend on that default staying put. Note the suffix is decimal and
# must be upper case — the adapter rejects "400gb".
MAP_SIZE = os.environ.get("BENCH_ARCTICDB_MAP_SIZE", "400GB")

# One Arctic instance for the lifetime of the process: LMDB refuses to have
# the same path opened twice from one process ("You should only open a
# single Arctic instance over a given LMDB path").
#
# columns_per_segment=1 is the one library option that departs from
# ArcticDB's defaults, and it is a layout decision rather than a tuning
# knob. ArcticDB tiles a symbol across both rows and columns and reads only
# the segments a query needs, but the default tile is 127 columns wide —
# wider than the 105 columns of `hits`, so the whole table would land in a
# single column slice and `columns=[...]` would prune nothing off disk.
# One column per segment gives the columnar layout the docs describe.
arctic = Arctic(f"lmdb://{STORE}?map_size={MAP_SIZE}")
lib = arctic.get_library(
    LIBRARY,
    create_if_missing=True,
    library_options=LibraryOptions(columns_per_segment=1),
)

app = FastAPI()


def read(columns=None, query=None, **kwargs):
    """lib.read shorthand returning the pandas frame.

    `columns` is what makes column pruning happen for filter-only queries:
    with columns=None ArcticDB decides that every column is required and
    reads all 105 of them off disk. It must NOT be passed alongside a
    groupby().agg() query — ArcticDB rejects that combination outright
    ("Cannot combine provided clauses with column selection") and instead
    prunes to the clause's own input columns automatically.
    """
    return lib.read(SYMBOL, columns=columns, query_builder=query, **kwargs).data


def col(name):
    """A bare column reference for use inside a QueryBuilder expression."""
    return QueryBuilder()[name]


def let(value, fn):
    """Bind an intermediate result inside a single expression.

    queries.sql holds one Python *expression* per line, and several of the
    43 queries need the same frame twice (once to derive a column, once to
    group by it). let(x, lambda d: ...) keeps those on one line without
    reading the symbol twice.
    """
    return fn(value)


# Names visible to a query expression. Deliberately small: `lib` and
# `SYMBOL` are there so a query can reach past the `read` helper if it
# needs to.
QUERY_SCOPE = {
    "lib": lib,
    "SYMBOL": SYMBOL,
    "read": read,
    "col": col,
    "let": let,
    "Q": QueryBuilder,
    "where": adb.where,
    "pd": pd,
    # Query 29 needs re.DOTALL to match ClickHouse's regex dialect, whose
    # `.` matches a newline where Python's does not. Five of the ~87M
    # non-empty Referers contain one, and without the flag they fall out of
    # their group because the anchored pattern stops matching.
    "re": re,
}


@app.get("/health")
def health():
    return {"ok": True}


def _prepare(table, offset):
    df = table.to_pandas()
    # Both conversions below are pinned to explicit dtypes rather than left
    # to pandas' inference, because the inference moved: pandas >= 2.2
    # gives to_datetime(unit=...) the narrowest resolution that fits
    # (datetime64[s] here, not [ns]), and pyarrow's to_pandas() returns the
    # StringDtype extension array rather than object once
    # `future.infer_string` is on. ArcticDB wants nanosecond datetimes and
    # object columns of Python str, and which pandas 2.x `pip install
    # arcticdb` resolves to is not ours to choose.
    for name in SECONDS_COLUMNS:
        df[name] = pd.to_datetime(df[name], unit="s").astype("datetime64[ns]")
    for name in DAYS_COLUMNS:
        df[name] = pd.to_datetime(df[name], unit="D").astype("datetime64[ns]")
    for name in df.columns:
        if df[name].dtype == object or pd.api.types.is_string_dtype(df[name]):
            df[name] = df[name].astype(object).fillna("")
    # ArcticDB stores a RangeIndex as (start, step) metadata and writes no
    # index column at all, which is what we want for a table that has no
    # meaningful time index — but an append has to continue the previous
    # range exactly, or it fails with "a RangeIndex.start=... that is not
    # contiguous with the stop".
    df.index = pd.RangeIndex(offset, offset + len(df))
    return df


def _load():
    start = timeit.default_timer()
    if lib.has_symbol(SYMBOL):
        lib.delete(SYMBOL)
    offset = 0
    buffered = []
    buffered_rows = 0

    def flush():
        nonlocal offset, buffered, buffered_rows
        if not buffered:
            return
        df = _prepare(pa.Table.from_batches(buffered), offset)
        buffered = []
        buffered_rows = 0
        if offset == 0:
            lib.write(SYMBOL, df)
        else:
            lib.append(SYMBOL, df)
        offset += len(df)

    for batch in pq.ParquetFile(PARQUET).iter_batches(batch_size=CHUNK_ROWS):
        buffered.append(batch)
        buffered_rows += batch.num_rows
        if buffered_rows >= CHUNK_ROWS:
            flush()
    flush()
    # Every append made a new version, and each version's index key lists
    # every segment written so far. The data segments are shared between
    # versions so this frees no bulk data, but it drops ~100 stale index
    # keys before ./data-size is measured.
    lib.prune_previous_versions(SYMBOL)
    return {"elapsed": round(timeit.default_timer() - start, 3), "rows": offset}


@app.post("/load")
async def load():
    return await run_in_threadpool(_load)


def _query(compiled):
    start = timeit.default_timer()
    value = eval(compiled, dict(QUERY_SCOPE))
    # Rendering the result is part of the timed run: ClickBench measures
    # back-to-back runtimes including returning the result to the client
    # (issue #1397).
    result = str(value)
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "result": result}


@app.post("/query")
async def query(request: Request):
    if not lib.has_symbol(SYMBOL):
        raise HTTPException(status_code=409, detail="hits not loaded; POST /load first")
    code = (await request.body()).decode("utf-8").strip()
    if not code:
        raise HTTPException(status_code=400, detail="empty query")
    try:
        compiled = compile(code, "<query>", "eval")
    except SyntaxError as e:
        raise HTTPException(status_code=400, detail=f"syntax error: {e}")
    # Off the event loop: a query can run for minutes, and the concurrent-QPS
    # watchdog polls /health every 5s. Blocking the loop would make it
    # conclude the server had died and restart it mid-window.
    return await run_in_threadpool(_query, compiled)


@app.get("/data-size")
def data_size():
    """Blocks allocated to the LMDB store, in bytes.

    Same number ./data-size gets from `du`; the route exists so it can be
    read without shell access.
    """
    total = 0
    for root, _dirs, files in os.walk(STORE):
        for name in files:
            try:
                total += os.stat(os.path.join(root, name)).st_blocks * 512
            except OSError:
                pass
    return {"bytes": total}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_ARCTICDB_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
