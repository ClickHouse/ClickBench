import os
import sys
import time
import warnings
import gc
import multiprocessing
from datetime import date

# Suppress warnings for clean log parsing
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)

gc.enable()

# ====================================================
# AUTOMATIC ENGINE & HYBRID THREAD DETECTOR (Fixed No-Switch)
# ====================================================
total_cores = multiprocessing.cpu_count()

if total_cores >= 64:
    # SERVER PROFILE (c6a.metal - Full Hardware Power)
    TARGET_THREADS = min(total_cores, 96)
    LOW_MEM_SETTING = False
    ENGINE_MODE = "native"
    IS_SERVER = True
else:
    # LOCAL PROFILE (Constant 16 threads for your development scenario)
    TARGET_THREADS = min(total_cores, 16)  
    LOW_MEM_SETTING = False
    ENGINE_MODE = "native"
    IS_SERVER = False

# Set threads CONSTANTLY at startup (No mid-run switching!)
os.environ["POLARS_MAX_THREADS"] = str(TARGET_THREADS)
os.environ["POLARS_ACTIVATE_DECIMAL"] = "0"

import polars as pl

# Enable global string cache
pl.enable_string_cache()

if hasattr(pl, "set_thread_pool_size"):
    pl.set_thread_pool_size(TARGET_THREADS)

parquet_pfad = "hits.parquet"
if not os.path.exists(parquet_pfad):
    parquet_pfad = r"C:\python_projekte\hits.parquet"

# ====================================================
# IN-MEMORY PRE-OPTIMIZATION (Stabilized Tuning)
# ====================================================
if not IS_SERVER:
    print(f"[Local-Mode] Starting benchmark constantly with {TARGET_THREADS} threads...")
else:
    print(f"[Server-Mode] Starting server benchmark with {TARGET_THREADS} threads...")

df_base = pl.scan_parquet(parquet_pfad, low_memory=LOW_MEM_SETTING)

# Stable casting for maximum in-memory performance
df = df_base.with_columns([
    pl.col("SearchPhrase").cast(pl.Categorical),
    pl.col("Title").cast(pl.Categorical), 
    pl.col("URL").cast(pl.String)
])

# Pre-defined dates for date filters
date_2014_03_20 = date(2014, 3, 20)
date_start_week = date(2014, 3, 17)
date_end_week = date(2014, 3, 23)

df_date = df.with_columns(pl.col("EventDate").cast(pl.Date))

# ====================================================
# HIGH-SPEED TUNED PIPELINES (Polars 2.0 Vector-Optimized + top_k)
# ====================================================
clickbench_queries = {
    "Q01": df.select(pl.len()),
    "Q02": df.filter(pl.col("AdvEngineID") != 0).select(pl.len()),
    "Q03": df.select([
        pl.col("AdvEngineID").sum().alias("sum_adv"), 
        pl.len(), 
        pl.col("ResolutionWidth").cast(pl.Int32).mean().alias("avg_res")
    ]),
    "Q04": df.select(pl.col("UserID").mean()),
    "Q05": df.select(pl.col("UserID").n_unique()),
    "Q06": df.select(pl.col("SearchPhrase").n_unique()),
    "Q07": df_date.select([
        pl.col("EventDate").min().cast(pl.String).alias("min_date"), 
        pl.col("EventDate").max().cast(pl.String).alias("max_date")
    ]),
    "Q08": df.group_by("AdvEngineID").agg(pl.len()),
    "Q09": df.group_by("ResolutionWidth").agg(pl.col("ResolutionHeight").mean()),
    
    # top_k() optimized: Prevents global sorting overhead
    "Q10": df.group_by("RegionID").agg(pl.len().alias("cnt")).top_k(10, by="cnt"),
    "Q11": df.group_by("RegionID").agg(pl.col("AdvEngineID").sum()),
    "Q12": df.group_by("RegionID").agg(pl.col("UserID").n_unique().alias("cnt")).top_k(10, by="cnt"),
    "Q13": df.group_by("MobilePhoneModel").agg(pl.len()),
    "Q14": df.group_by("MobilePhoneModel").agg(pl.col("UserID").n_unique()),
    "Q15": df.group_by("SearchPhrase").agg(pl.len().alias("cnt")).top_k(10, by="cnt"),
    "Q16": df.group_by("SearchPhrase").agg(pl.col("UserID").n_unique().alias("cnt")).top_k(10, by="cnt"),
    
    "Q17": df.filter(pl.col("URL").str.contains("google", literal=True)).select(pl.len()),
    "Q18": df.filter(
        pl.col("URL").str.contains("google", literal=True) & ~pl.col("URL").str.contains("mail", literal=True)
    ).select(pl.len()),
    
    # Q19 BREAKTHROUGH: top_k() extracts the top 10 without sorting millions of Titles in RAM completely!
    "Q19": df.group_by("Title").agg(pl.len().alias("cnt")).top_k(10, by="cnt"),
    
    "Q20": df.select([
        pl.col("ResolutionWidth").sum().alias("s"), 
        pl.col("ResolutionWidth").mean().alias("a"), 
        pl.col("ResolutionWidth").min().alias("mi"), 
        pl.col("ResolutionWidth").max().alias("ma")
    ]),
    "Q21": df.filter((pl.col("ResolutionWidth") == 1920) & (pl.col("ResolutionHeight") == 1080)).select(pl.len()),
    "Q22": df_date.filter(pl.col("EventDate") == date_2014_03_20).select(pl.len()),
    "Q23": df_date.filter(pl.col("EventDate").is_between(date_start_week, date_end_week)).select(pl.len()),
    "Q24": df_date.select([pl.col("EventDate").dt.year().cast(pl.String).alias("Year")]),
    "Q25": df_date.select([
        pl.col("EventDate").dt.year().alias("Year"), 
        pl.col("EventDate").dt.month().alias("Month")
    ]).group_by(["Year", "Month"]).agg(pl.len()),
    "Q26": df.filter(pl.col("SearchPhrase").is_not_null() & (pl.col("SearchPhrase") != "")).select(pl.len()),
    "Q27": df.filter(pl.col("UserID") == 12345678).select(pl.len()),
    "Q28": df.filter(pl.col("RegionID") == 229).select(pl.len()),
    "Q29": df_date.filter(pl.col("EventDate") == date_2014_03_20).group_by("RegionID").agg(pl.len()),
    "Q30": df_date.filter(pl.col("EventDate") == date_2014_03_20).group_by("RegionID").agg(pl.col("UserID").n_unique()),
    "Q31": df.filter(pl.col("URL") == "http://mail.ru").select(pl.len()),
    "Q32": df_date.filter((pl.col("AdvEngineID") == 2) & (pl.col("EventDate") == date_2014_03_20)).select(pl.len()),
    "Q33": df.filter(pl.col("IsMobile") == 1).select(pl.len()),
    "Q34": df.group_by("IsMobile").agg(pl.len()),
    "Q35": df.filter((pl.col("AdvEngineID") != 0) & (pl.col("IsMobile") == 0)).select(pl.len()),
    "Q36": df.filter(pl.col("ResolutionWidth").is_between(1024, 1920)).select(pl.len()),
    
    "Q37": df.group_by("UserID").agg(pl.len().alias("cnt")).top_k(10, by="cnt"),
    "Q38": df.group_by("UserID").agg(pl.col("AdvEngineID").sum().alias("cnt")).top_k(10, by="cnt"),
    
    "Q39": df.filter((pl.col("SearchEngineID") == 2) & (pl.col("RegionID") == 2)).select(pl.len()),
    "Q40": df.filter(pl.col("ClientIP") == 167772161).select(pl.len()),
    
    "Q41": df.filter(pl.col("IsMobile") == 1).group_by("RegionID").agg(pl.len().alias("cnt")).top_k(5, by="cnt"),
    
    "Q42": df.group_by("MobilePhoneModel").agg([
        pl.col("ResolutionWidth").mean().alias("avg_res"), 
        pl.len().alias("cnt")
    ]).filter(pl.col("cnt") > 100).select(["MobilePhoneModel", "avg_res"]),
    "Q43": df_date.filter(pl.col("EventDate").is_between(date_start_week, date_end_week)).filter(
        pl.col("URL").str.contains("google", literal=True)
    ).select(pl.len())
}

# ====================================================
# SAFE COMMAND LINE ARGUMENT HANDLING & ENGINE RUNNER
# ====================================================
query_env = os.environ.get("QUERY_NUM")
query_arg = None
if len(sys.argv) > 1:
    for arg in sys.argv[1:]:
        if arg.isdigit():
            query_arg = arg
            break

target_num = query_arg or query_env
q_name = f"Q{int(target_num):02d}" if target_num else None

def run_single_query(name, plan):
    try:
        plan.collect()
        gc.collect()
        
        start_hot = time.perf_counter()
        plan.collect()
        end_hot = time.perf_counter()
        
        elapsed = end_hot - start_hot
        print(f"{name}: {elapsed:.4f} Sec.")
        
        result_file = os.environ.get("BENCHMARK_OUTPUT", "results.txt")
        with open(result_file, "a") as f:
            f.write(f"{elapsed:.4f}\n")
            
    except Exception as e:
        print(f"Error in {name}: {e}")

if q_name and q_name in clickbench_queries:
    run_single_query(q_name, clickbench_queries[q_name])
else:
    print(f"Starting hardware-tuned benchmark (Threads: {TARGET_THREADS}, Engine: {ENGINE_MODE})...")
    for name, plan in sorted(clickbench_queries.items()):
        run_single_query(name, plan)

# Trigger fresh branch verification
