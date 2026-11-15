#!/usr/bin/env python3
"""FastAPI wrapper around polars so it conforms to the ClickBench
install/start/check/stop/load/query interface.
"""

import gc
import os
import sys
import timeit
import warnings
from datetime import date

warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)
gc.enable()

try:
    import mechanicus_core
    print(mechanicus_core.verify_spirit())
except ImportError:
    print("Mechanicus-Core not compiled yet. Running in baseline mode.")

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request

pl.enable_string_cache()

# Restore output formatting configurations to avoid truncation in verification
pl.Config.set_tbl_rows(-1)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_width_chars(-1)
pl.Config.set_fmt_str_lengths(65535)

app = FastAPI()
hits: pl.DataFrame | None = None
parquet_path: str = "hits.parquet"


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    
    # Load and perform only the mandatory baseline schema casting (EventTime and EventDate)
    hits = pl.read_parquet(parquet_path, low_memory=False).with_columns(
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
        compiled = compile(code, "QUERY", "eval")
    except SyntaxError as e:
        raise HTTPException(status_code=400, detail=f"syntax error: {e}")
    
    start = timeit.default_timer()
    value = eval(compiled, {"hits": hits.lazy(), "pl": pl, "date": date})
    
    if isinstance(value, (pl.DataFrame, pl.Series, pl.LazyFrame)):
        if isinstance(value, pl.LazyFrame):
            result = str(value.collect())
        else:
            result = str(value)
    else:
        result = repr(value)
    
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "result": result}


@app.get("/data-size")
def data_size():
    if hits is not None:
        try:
            return {"bytes": hits.estimated_size()}
        except Exception:
            return {"bytes": 0}
    return {"bytes": 0}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_POLARS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
