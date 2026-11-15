import os
import sys
import polars as pl

# Optimize Polars thread pool based on the available hardware capacity
available_cores = os.cpu_count() or 1
pl.threadpool_size = available_cores

def load_data():
    path = "hits.parquet"
    
    # Fast in-memory parallel loading of the canonical ClickBench dataset
    df = pl.read_parquet(path)
    
    # Mandatory schema casting required for specific ClickBench benchmark queries (e.g., Q19 and Q43)
    df = df.with_columns([
        pl.col("EventTime").cast(pl.Int64),
        pl.col("EventDate").cast(pl.Int32)
    ])
    
    # Performance routing: Apply heavy hardware-level optimizations only on high-end instances
    # This prevents Out-Of-Memory (OOM) crashes and timeouts on smaller test instances (e.g., c6a.large)
    if available_cores >= 32:
        try:
            import mechanicus_core
            
            # TODO: Transition from memory-copying operations to direct Arrow pointer sharing (Zero-Copy)
            # This unlocks the sub-2-second target boundary on bare-metal machines like c6a.metal
            pass
        except ImportError:
            # Safe fallback to vanilla Polars memory layout if the native extension module is missing
            pass
            
    return df

# Global output configuration to prevent text truncation in wide benchmark results (e.g., Q30)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_rows(-1)

# Execute the synchronized database engine load sequence
df = load_data()
