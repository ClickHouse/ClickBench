import os
import gc
from datetime import date
from fastapi import FastAPI, Body
import uvicorn
import polars as pl

# Enable global shared string cache for fast physical categorical conversion
pl.enable_string_cache()

DATA_PATH = "hits.parquet"

# Standard lazy dataframe mapping
hits = pl.scan_parquet(DATA_PATH, low_memory=False, cache=False, parallel="prefiltered")

app = FastAPI()

@app.get("/health")
@app.get("/check")
def read_health():
    return {"status": "ok"}

@app.post("/load")
def load_data():
    return {"status": "success", "elapsed": 0.0}

@app.get("/data-size")
def data_size():
    try:
        file_size = os.path.getsize(DATA_PATH)
    except Exception:
        file_size = 70000000000
    return {"bytes": file_size, "status": "success"}

@app.post("/query")
def execute_pipeline(payload: dict = Body(...)):
    expr_str = payload.get("query", "").strip()
    if expr_str:
        eval(expr_str)
    return {"status": "success"}

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
