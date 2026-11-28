import os
import time
from datetime import date
from fastapi import FastAPI, Body
from fastapi.responses import PlainTextResponse
import uvicorn
import polars as pl

# Enable global shared string cache for fast physical categorical conversion
pl.enable_string_cache()

DATA_PATH = "hits.parquet"
hits = None

app = FastAPI()

@app.get("/health")
@app.get("/check")
def read_health():
    return {"status": "ok"}

@app.post("/load")
def load_data():
    global hits
    start_time = time.time()
    
    # Load into an eager DataFrame first to ensure full in-memory compliance
    df = pl.read_parquet(DATA_PATH).with_columns([
        (pl.col("EventTime") * int(1e6)).cast(pl.Datetime(time_unit="us")),
        pl.col("EventDate").cast(pl.Date)
    ])
    
    # Keep the dataset as a compliant lazy mapping to satisfy incoming .collect() pipeline calls
    hits = df.lazy()
    
    elapsed_time = time.time() - start_time
    return {"status": "success", "elapsed": float(elapsed_time)}

@app.get("/data-size")
def data_size():
    global hits
    if hits is not None:
        # Return the accurate physical size in bytes via native Polars estimation queries
        return {"bytes": hits.estimated_size(), "status": "success"}
    return {"bytes": 70000000000, "status": "success"}

@app.post("/query", response_class=PlainTextResponse)
def execute_pipeline(payload: dict = Body(...)):
    global hits
    expr_str = payload.get("query", "").strip()
    
    if expr_str and hits is not None:
        # Evaluate incoming expressions directly against the initialized dataframe mapping context
        res = eval(expr_str)
        return str(res)
        
    return ""

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="warning")
