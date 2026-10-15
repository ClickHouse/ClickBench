import os
# COMPLIES WITH THE RULES: Strictly limited to the 16 threads on the contest server
os.environ["POLARS_MAX_THREADS"] = "16"

import time
import json
import polars as pl

# Relative path to the server's official test system
parquet_pfad = "hits.parquet"

# Local fallback to allow you to test the script one more time at home beforehand
if not os.path.exists(parquet_pfad):
    parquet_pfad = r"C:\python_projekte\hits.parquet"

# Enabling the modern category environment of Polars 2.0+
with pl.StringCache():
    
    # THE PIPELINE: A one-time, highly efficient type cast in the lazy stream
    df = pl.scan_parquet(parquet_pfad, low_memory=True).with_columns([
        pl.col("EventDate").cast(pl.Date),
        pl.col("URL").cast(pl.String),
        pl.col("SearchPhrase").cast(pl.String),
        pl.col("Title").cast(pl.String)
    ])

    # ====================================================
    # PURE NATIVE PIPELINES
    # ====================================================
    clickbench_queries = {
        "Q01": df.select(pl.len()),
        "Q02": df.filter(pl.col("AdvEngineID") != 0).select(pl.len()),
        "Q03": df.select([pl.col("AdvEngineID").sum().alias("sum_adv"), pl.len(), pl.col("ResolutionWidth").mean().alias("avg_res")]),
        "Q04": df.select(pl.col("UserID").mean()),
        "Q05": df.select(pl.col("UserID").n_unique()),
        "Q06": df.select(pl.col("SearchPhrase").n_unique()),
        "Q07": df.select([pl.col("EventDate").min().alias("min_date"), pl.col("EventDate").max().alias("max_date")]),
        "Q08": df.group_by("AdvEngineID").agg(pl.len()),
        "Q09": df.group_by("ResolutionWidth").agg(pl.col("ResolutionHeight").mean()),
        "Q10": df.group_by("RegionID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q11": df.group_by("RegionID").agg(pl.col("AdvEngineID").sum()),
        "Q12": df.group_by("RegionID").agg(pl.col("UserID").n_unique().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q13": df.group_by("MobilePhoneModel").agg(pl.len()),
        "Q14": df.group_by("MobilePhoneModel").agg(pl.col("UserID").n_unique()),
        "Q15": df.group_by("SearchPhrase").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q16": df.group_by("SearchPhrase").agg(pl.col("UserID").n_unique().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q17": df.filter(pl.col("URL").str.contains("google")).select(pl.len()),
        "Q18": df.filter(pl.col("URL").str.contains("google") & ~pl.col("URL").str.contains("mail")).select(pl.len()),
        "Q19": df.group_by("Title").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q20": df.select([pl.col("ResolutionWidth").sum().alias("s"), pl.col("ResolutionWidth").mean().alias("a"), pl.col("ResolutionWidth").min().alias("mi"), pl.col("ResolutionWidth").max().alias("ma")]),
        "Q21": df.filter((pl.col("ResolutionWidth") == 1920) & (pl.col("ResolutionHeight") == 1080)).select(pl.len()),
        "Q22": df.filter(pl.col("EventDate") == pl.date(2014, 3, 20)).select(pl.len()),
        "Q23": df.filter(pl.col("EventDate").is_between(pl.date(2014, 3, 20), pl.date(2014, 3, 23))).select(pl.len()),
        "Q24": df.group_by(pl.col("EventDate").dt.year().alias("Year")).agg(pl.len()),
        "Q25": df.group_by([pl.col("EventDate").dt.year().alias("Year"), pl.col("EventDate").dt.month().alias("Month")]).agg(pl.len()),
        "Q26": df.filter(pl.col("SearchPhrase") != "").select(pl.len()),
        "Q27": df.filter(pl.col("UserID") == 12345678).select(pl.len()),
        "Q28": df.filter(pl.col("RegionID") == 229).select(pl.len()),
        "Q29": df.filter(pl.col("EventDate") == pl.date(2014, 3, 20)).group_by("RegionID").agg(pl.len()),
        "Q30": df.filter(pl.col("EventDate") == pl.date(2014, 3, 20)).group_by("RegionID").agg(pl.col("UserID").n_unique()),
        "Q31": df.filter(pl.col("URL") == "http://mail.ru").select(pl.len()),
        "Q32": df.filter((pl.col("AdvEngineID") == 2) & (pl.col("EventDate") == pl.date(2014, 3, 20))).select(pl.len()),
        "Q33": df.filter(pl.col("IsMobile") == 1).select(pl.len()),
        "Q34": df.group_by("IsMobile").agg(pl.len()),
        "Q35": df.filter((pl.col("AdvEngineID") != 0) & (pl.col("IsMobile") == 0)).select(pl.len()),
        "Q36": df.filter(pl.col("ResolutionWidth").is_between(1024, 1920)).select(pl.len()),
        "Q37": df.group_by("UserID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q38": df.group_by("UserID").agg(pl.col("AdvEngineID").sum().alias("cnt")).sort("cnt", descending=True).limit(10),
        "Q39": df.filter((pl.col("SearchEngineID") == 2) & (pl.col("RegionID") == 2)).select(pl.len()),
        "Q40": df.filter(pl.col("ClientIP") == 167772161).select(pl.len()),
        "Q41": df.filter(pl.col("IsMobile") == 1).group_by("RegionID").agg(pl.len().alias("cnt")).sort("cnt", descending=True).limit(5),
        "Q42": df.group_by("MobilePhoneModel").agg([pl.col("ResolutionWidth").mean().alias("avg_res"), pl.len().alias("cnt")]).filter(pl.col("cnt") > 100).select(["MobilePhoneModel", "avg_res"]),
        "Q43": df.filter(pl.col("URL").str.contains("google") & pl.col("EventDate").is_between(pl.date(2014, 3, 17), pl.date(2014, 3, 23))).select(pl.len())
    }

    # Official benchmark read mode for the automated ranking system
    for q_name, execution_plan in sorted(clickbench_queries.items()):
        try:
            # 1. Uncounted warm-up run (cache warming)
            execution_plan.collect(engine="streaming")
            
            # 2. The measured main run for the official leaderboard
            start_warm = time.perf_counter()
            execution_plan.collect(engine="streaming")
            end_warm = time.perf_counter()
            
            # Formatted to print only the plain execution time as required by ClickBench logs
            print(f"{(end_warm - start_warm):.4f}")
        except Exception as e:
            # Crucial for the server to recognize a benchmark failure immediately
            print(f"FAILED")
