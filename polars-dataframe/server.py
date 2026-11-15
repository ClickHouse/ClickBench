import os
import sys
import time
import uvicorn
from fastapi import FastAPI, Request, Response
import polars as pl

app = FastAPI()

available_cores = os.cpu_count() or 1
pl.threadpool_size = available_cores

state = {"df": None}

def load_data():
    path = "hits.parquet"
    df = pl.read_parquet(path)
    
    # Correct timestamp scaling to prevent the 1970 microsecond shift
    df = df.with_columns([
        (pl.col("EventTime") * 1_000_000).cast(pl.Datetime),
        pl.col("EventDate").cast(pl.Date)
    ])
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
    if state["df"] is not None:
        # Returns the raw text value expected by data-size script
        return Response(content=str(state["df"].estimated_size()), media_type="text/plain")
    return Response(content="0", media_type="text/plain")

@app.post("/query")
async def query_endpoint(request: Request):
    body = await request.body()
    query_str = body.decode("utf-8").strip()
    
    if state["df"] is None:
        state["df"] = load_data()
        
    start_time = time.time()
    try:
        # Fallback to standard eager execution loop for canonical queries
        # Executes the benchmark query safely without mixing text formats
        result = state["df"].lazy().sql(query_str).collect()
        print(result)
    except Exception:
        # Strict compatibility fallback if direct SQL mapping fails
        try:
            ctx = pl.SQLContext(hits=state["df"])
            result = ctx.execute(query_str, eager=True)
            print(result)
        except Exception as e:
            return Response(content=str(e), status_code=500)
        
    elapsed = time.time() - start_time
    # Returns the plain elapsed time string required by query script contract
    return Response(content=str(elapsed), media_type="text/plain")

if __name__ == "__main__":
    pl.Config.set_tbl_cols(-1)
    pl.Config.set_tbl_rows(-1)
    uvicorn.run(app, host="127.0.0.1", port=8000, log_level="info")
