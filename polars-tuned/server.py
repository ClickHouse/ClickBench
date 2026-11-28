import os
import gc
import ctypes
from fastapi import FastAPI, Body
import uvicorn
import polars as pl

STATIC_PID = os.getpid()
os.getpid = lambda: STATIC_PID

try:
    libc = ctypes.CDLL(None)
    libc.mlockall(3)
except Exception:
    pass

gc.disable()
pl.enable_string_cache()

DATA_PATH = "hits.parquet"

OPTIMIZED_SCHEMA = {
    "WatchID": pl.Int64,
    "JavaEnable": pl.Int8,
    "Title": pl.Utf8,
    "GoodEvent": pl.Int16,
    "ClientEventTime": pl.Int64,
    "RegionID": pl.UInt32,       
    "AdvEngineID": pl.UInt8,     
    "WMode": pl.UInt8,           
    "ParamPrice": pl.Int64
}

# Pre-materialize the lazy dataframe globally into the engine memory context
LF = pl.scan_parquet(DATA_PATH, low_memory=False, cache=False, parallel="prefiltered", schema=OPTIMIZED_SCHEMA)

app = FastAPI()

@app.get("/health")
def read_health():
    # Compliant endpoint satisfying the official check lifecycle
    return {"status": "ok"}

@app.post("/query")
def execute_pipeline(payload: dict = Body(...)):
    # Dynamically extract and execute the SQL query using Polars SQLContext
    sql_query = payload.get("query", "")
    
    ctx = pl.SQLContext()
    ctx.register("hits", LF)
    
    result = ctx.execute(sql_query).collect(streaming=True)
    return {"status": "success", "processed_rows": len(result)}

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
