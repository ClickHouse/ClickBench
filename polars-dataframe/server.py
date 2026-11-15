import os
import sys
import time
import uvicorn
from fastapi import FastAPI, Request, Response
import polars as pl

app = FastAPI()

available_cores = os.cpu_count() or 1
pl.threadpool_size = available_cores

# ClickBench test suite addresses the base data matrix as global variable 'hits'
state = {"df": None}
hits = None

def load_data():
    global hits
    path = "hits.parquet"
    df = pl.read_parquet(path)
    
    # Correct timestamp scaling to prevent microsecond parsing shifts
    df = df.with_columns([
        (pl.col("EventTime") * 1_000_000).cast(pl.Datetime),
        pl.col("EventDate").cast(pl.Date)
    ])
    hits = df
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
    # Contract requires JSON return mapping containing evaluated byte metrics
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
        # Framework executing logic: evaluate the incoming Python expression string directly
        # 'hits' is globally exposed inside the expression namespace boundary
        result = eval(query_str)
        print(result)
    except Exception as e:
        return Response(content=str(e), status_code=500)
        
    elapsed = time.time() - start_time
    # Returns synchronized execution performance tracking metrics back to reporting script
    return {"elapsed": elapsed}

if __name__ == "__main__":
    pl.Config.set_tbl_cols(-1)
    pl.Config.set_tbl_rows(-1)
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
