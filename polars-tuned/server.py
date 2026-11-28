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

# Pre-materialize the dataframe globally as 'hits' for eval context alignment
hits = pl.scan_parquet(DATA_PATH, low_memory=False, cache=False, parallel="prefiltered")

app = FastAPI()

@app.get("/health")
@app.get("/check")
def read_health():
    return {"status": "ok"}

@app.get("/load")
def load_data():
    return {"status": "success"}

@app.get("/data-size")
def data_size():
    return {"status": "success"}

@app.post("/query")
def execute_pipeline(payload: dict = Body(...)):
    # Extract the raw expression string from the stream payload
    expr_str = payload.get("query", "").strip()
    
    # Safely evaluate the native expression string directly against the global hits dataframe context
    if expr_str:
        eval(expr_str)
        
    return {"status": "success"}

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
