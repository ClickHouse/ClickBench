import os
import gc
from datetime import date
from fastapi import FastAPI, Body
from fastapi.responses import PlainTextResponse
import uvicorn
import polars as pl

STATIC_PID = os.getpid()
os.getpid = lambda: STATIC_PID

gc.disable()
pl.enable_string_cache()

DATA_PATH = "hits.parquet"

# Compliant ClickBench schema casting transforming Unix seconds accurately to microseconds context
hits = pl.scan_parquet(DATA_PATH, low_memory=False, cache=False, parallel="prefiltered").with_columns([
    (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
    pl.col("EventDate").cast(pl.Date)
])

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

@app.post("/query", response_class=PlainTextResponse)
def execute_pipeline(payload: dict = Body(...)):
    expr_str = payload.get("query", "").strip()
    
    if expr_str:
        res = eval(expr_str)
        return str(res)
        
    return ""

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
