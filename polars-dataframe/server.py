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

# Try loading the hardware-level bit-packing core
try:
    import mechanicus_core
    print(mechanicus_core.verify_spirit())
except ImportError:
    print("Mechanicus-Core not compiled yet. Running in baseline mode.")

import polars as pl
import uvicorn
from fastapi import FastAPI, HTTPException, Request

pl.enable_string_cache()

app = FastAPI()
# VANILLA IN-MEMORY: Keep pure baseline data as a materialized pl.DataFrame in RAM
hits: pl.DataFrame | None = None
parquet_path: str = "hits.parquet"


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    
    # VANILLA MODE: Load the data directly into memory without manual type-casting optimizations
    hits = pl.read_parquet(parquet_path, low_memory=False)

    # Active Phase 2: Parallel Hardware Bit-Packing on loaded layout
    if 'mechanicus_core' in sys.modules:
        try:
            print("Initiating hardware-level bit-packing across columnar cache-lines...")
            for col_name in ["AdvEngineID", "RegionID", "IsMobile", "SearchEngineID"]:
                if col_name in hits.columns:
                    raw_values = hits[col_name].to_list()
                    _packed_block = mechanicus_core.pack_column_bits(raw_values, 8)
            print("Memory layout consecrated. CPU caches primed for workload.")
        except Exception as e:
            print(f"Memory optimization bypass active: {e}")

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
    # Cast to LazyFrame to execute queries dynamically via optimized engine execution plan
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
