import os
import sys
import time
import uvicorn
from datetime import date
from fastapi import FastAPI, Request, Response
import polars as pl

# Global configuration to prevent text truncation and wrapping in wide benchmark columns (e.g., Q24, Q30)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_rows(-1)
pl.Config.set_tbl_width_chars(-1)  # Fixes the Linux 'Argument list too long' error for Q24
pl.Config.set_fmt_str_lengths(1000)

app = FastAPI()

available_cores = os.cpu_count() or 1
pl.threadpool_size = available_cores

state = {"df": None}
hits = None

def load_data():
    global hits
    path = "hits.parquet"
    df = pl.read_parquet(path)
    
    df = df.with_columns([
        (pl.col("EventTime") * 1_000_000).cast(pl.Datetime),
        pl.col("EventDate").cast(pl.Date)
    ])
    
    hits = df.lazy()
    return df

@app.get("/health")
def health():
    return {"status": "ready"}

@app.post("/load")
def load_endpoint():
    start_time = time.time()
    if state["df"] is None:
        state["df"] = load_data()
    elapsed = time.time() - start_time
    return {"status": "success", "elapsed": elapsed}

@app.get("/data-size")
def data_size_endpoint():
    if state["df"] is None:
        state["df"] = load_data()
    return {"bytes": state["df"].estimated_size()}

@app.post("/query")
async def query_endpoint(request: Request):
    global hits
    body = await request.body()
    query_str = body.decode("utf-8").strip()
    
    if state["df"] is None:
        state["df"] = load_data()
        
    start_time = time.time()
    try:
        result = eval(query_str)
        result_str = str(result)
    except Exception as e:
        return Response(content=str(e), status_code=500)
        
    elapsed = time.time() - start_time
    
    return {
        "elapsed": elapsed,
        "result": result_str,
        "bytes": state["df"].estimated_size()
    }

if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
