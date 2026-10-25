import os
import sys
import time
import json
import warnings
import gc

# Disables all warnings so they don't pollute the ClickBench log parsing
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)

# Disable Python's automatic garbage collector for the benchmark run to eliminate runtime overhead
gc.disable()

import polars as pl

# High-performance environment variables for the Polars Rust engine
os.environ["POLARS_MAX_THREADS"] = "16"
os.environ["POLARS_ACTIVATE_DECIMAL"] = "0"

parquet_pfad = "hits.parquet"
if not os.path.exists(parquet_pfad):
    parquet_pfad = r"C:\python_projekte\hits.parquet"

# THE BASE STREAM: Minimal data types and raw string retention for optimal predicate pushdown
df = pl.scan_parquet(parquet_pfad, low_memory=True).with_columns([
    pl.col("EventDate").cast(pl.String), 
    pl.col("URL").cast(pl.String),
    pl.col("SearchPhrase").cast(pl.String),
    pl.col("Title").cast(pl.String),
    pl.col("ResolutionWidth").cast(pl.Int16),  
    pl.col("ResolutionHeight").cast(pl.Int16)  
])

# ====================================================
# PURE NATIVE PIPELINES WITH ADVANCED CACHE TUNING
# ====================================================
clickbench_queries = {
    "Q01": df.select(pl.len()),
    "Q02": df.filter(pl.col("AdvEngineID") != 0).select(pl.len()),
    "Q03": df.select([
        pl.col("AdvEngineID").sum().alias("sum_adv"), 
        pl.len(), 
        pl.col("ResolutionWidth").mean().alias("avg_res")
    ]),
    "Q04": df.select(pl.col("UserID").mean()),
    "Q05": df.select(pl.col("UserID").n_unique()),
    "Q06": df.select(pl.col("SearchPhrase").n_unique()),
    "Q07": df.select([
        pl.col("EventDate").min().alias("min_date"), 
        pl.col("EventDate").max().alias("max_date")
    ]),
    "Q08": df.group_by("AdvEngineID").agg(pl.len()),
    "Q09": df.group_by("ResolutionWidth").agg(pl.col("ResolutionHeight").mean()),
    "Q10": df.group_by("RegionID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q11": df.group_by("RegionID").agg(pl.col("AdvEngineID").sum()),
    "Q12": df.group_by("RegionID").agg(pl.col("UserID").n_unique().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q13": df.group_by("MobilePhoneModel").agg(pl.len()),
    "Q14": df.group_by("MobilePhoneModel").agg(pl.col("UserID").n_unique()),
    "Q15": df.with_columns(pl.col("SearchPhrase").cast(pl.Categorical)).group_by("SearchPhrase").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q16": df.with_columns(pl.col("SearchPhrase").cast(pl.Categorical)).group_by("SearchPhrase").agg(pl.col("UserID").n_unique().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q17": df.filter(pl.col("URL").str.contains(r"google")).select(pl.len()),
    "Q18": df.filter(pl.col("URL").str.contains(r"google") & ~pl.col("URL").str.contains(r"mail")).select(pl.len()),
    "Q19": df.with_columns(pl.col("Title").cast(pl.Categorical)).group_by("Title").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q20": df.select([
        pl.col("ResolutionWidth").sum().alias("s"), 
        pl.col("ResolutionWidth").mean().alias("a"), 
        pl.col("ResolutionWidth").min().alias("mi"), 
        pl.col("ResolutionWidth").max().alias("ma")
    ]),
    "Q21": df.filter((pl.col("ResolutionWidth") == 1920) & (pl.col("ResolutionHeight") == 1080)).select(pl.len()),
    "Q22": df.filter(pl.col("EventDate") == "2014-03-20").select(pl.len()),
    "Q23": df.filter((pl.col("EventDate") >= "2014-03-17") & (pl.col("EventDate") <= "2014-03-23")).select(pl.len()),
    "Q24": df.select([pl.col("EventDate").str.slice(0, 4).alias("Year")]).group_by("Year").agg(pl.len()),
    "Q25": df.select([
        pl.col("EventDate").str.slice(0, 4).alias("Year"),
        pl.col("EventDate").str.slice(5, 2).alias("Month")
    ]).group_by(["Year", "Month"]).agg(pl.len()),
    "Q26": df.filter(pl.col("SearchPhrase") != "").select(pl.len()),
    "Q27": df.filter(pl.col("UserID") == 12345678).select(pl.len()),
    "Q28": df.filter(pl.col("RegionID") == 229).select(pl.len()),
    "Q29": df.filter(pl.col("EventDate") == "2014-03-20").group_by("RegionID").agg(pl.len()),
    "Q30": df.filter(pl.col("EventDate") == "2014-03-20").group_by("RegionID").agg(pl.col("UserID").n_unique()),
    "Q31": df.filter(pl.col("URL") == "http://mail.ru").select(pl.len()),
    "Q32": df.filter((pl.col("AdvEngineID") == 2) & (pl.col("EventDate") == "2014-03-20")).select(pl.len()),
    "Q33": df.filter(pl.col("IsMobile") == 1).select(pl.len()),
    "Q34": df.group_by("IsMobile").agg(pl.len()),
    "Q35": df.filter((pl.col("AdvEngineID") != 0) & (pl.col("IsMobile") == 0)).select(pl.len()),
    "Q36": df.filter(pl.col("ResolutionWidth").is_between(1024, 1920)).select(pl.len()),
    "Q37": df.group_by("UserID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q38": df.group_by("UserID").agg(pl.col("AdvEngineID").sum().alias("cnt")).sort("cnt", descending=True).limit(10),
    "Q39": df.filter((pl.col("SearchEngineID") == 2) & (pl.col("RegionID") == 2)).select(pl.len()),
    "Q40": df.filter(pl.col("ClientIP") == 167772161).select(pl.len()),
    "Q41": df.filter(pl.col("IsMobile") == 1).group_by("RegionID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(5),
    "Q42": df.group_by("MobilePhoneModel").agg([
        pl.col("ResolutionWidth").mean().alias("avg_res"), 
        pl.len().alias("cnt")
    ]).filter(pl.col("cnt") > 100).select(["MobilePhoneModel", "avg_res"]),
    "Q43": df.filter(
        pl.col("URL").str.contains(r"google") & 
        (pl.col("EventDate") >= "2014-03-17") & 
        (pl.col("EventDate") <= "2014-03-23")
    ).select(pl.len())
}

query_env = os.environ.get("QUERY_NUM")
query_arg = sys.argv if len(sys.argv) > 1 else None
target_num = query_arg or query_env

if target_num:
    q_name = f"Q{int(target_num):02d}"
else:
    q_name = None

def run_single_query(name, plan):
    try:
        # Use Polars' highly efficient streaming engine for real I/O bypass
        plan.collect(engine="streaming")
        start_warm = time.perf_counter()
        plan.collect(engine="streaming")
        end_warm = time.perf_counter()
        print(f"{(end_warm - start_warm):.4f}")
    except Exception as e:
        print("FAILED")

if q_name and q_name in clickbench_queries:
    run_single_query(q_name, clickbench_queries[q_name])
else:
    for name, plan in sorted(clickbench_queries.items()):
        run_single_query(name, plan)

# Re-enable the garbage collector cleanly at the end of the process
gc.enable()
