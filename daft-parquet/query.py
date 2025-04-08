#!/usr/bin/env python3

import daft
import timeit
import traceback
import pandas as pd
from daft import col, DataType, TimeUnit
from pathlib import Path

hits = None

with open("queries.sql") as f:
    sql_list = [q.strip() for q in f.read().split(';') if q.strip()]

def daft_offset(df, start ,end):
    pandas_df = df.to_pandas()
    sliced_df = pandas_df.iloc[start:end]
    return sliced_df

queries = []
for idx, sql in enumerate(sql_list):
    query_entry = {"sql": sql}

    if idx+1 in [19, 36, 43]:
        if idx+1 == 19:
            query_entry["lambda"] = lambda: (
                hits.with_column("m", col("EventTime").dt.minute())
                    .groupby("UserID", "m", "SearchPhrase")
                    .agg(daft.sql_expr("COUNT(1)").alias("COUNT(*)"))
                    .sort("COUNT(*)", desc=True)
                    .limit(10)
                    .select("UserID", "m", "SearchPhrase", "COUNT(*)")
            )
        elif idx+1 == 36:
            query_entry["lambda"] = lambda: (
                hits.groupby(
                        "ClientIP",
                        daft.sql_expr("ClientIP - 1").alias("ClientIP - 1"),
                        daft.sql_expr("ClientIP - 2").alias("ClientIP - 2"),
                        daft.sql_expr("ClientIP - 3").alias("ClientIP - 3"))
                    .agg(daft.sql_expr("COUNT(1)").alias("c"))
                    .sort("c", desc=True)
                    .limit(10)
                    .select("ClientIP", "ClientIP - 1", "ClientIP - 2", "ClientIP - 3", "c")
            )
        elif idx+1 == 43:
            query_entry["lambda"] = lambda: (
                hits.with_column("M", col("EventTime").dt.truncate("1 minute"))
                    .where("CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0")
                    .groupby("M")
                    .agg(daft.sql_expr("COUNT(1)").alias("PageViews"))
                    .sort("M", desc=False)
                    .limit(1010)
                    .select("M", "PageViews")
            )

    if 39 <= idx+1 <= 43:
        if idx+1 == 39:
            query_entry["extra_api"] = lambda df: daft_offset(df, 1000, 1010)
        elif idx+1 == 40:
            query_entry["extra_api"] = lambda df: daft_offset(df, 1000, 1010)
        elif idx+1 == 41:
            query_entry["extra_api"] = lambda df: daft_offset(df, 100, 110)
        elif idx+1 == 42:
            query_entry["extra_api"] = lambda df: daft_offset(df, 10000, 10010)
        elif idx+1 == 43:
            query_entry["extra_api"] = lambda df: daft_offset(df, 1000, 1010)

    queries.append(query_entry)

def run_single_query(query, i):
    try:
        start = timeit.default_timer()

        global hits
        if hits is None:
            # Use for Daft (Parquet, partitioned)
            # Use absolute path when using wildcards
            # hits = daft.read_parquet("/path/to/hits_*.parquet")

            # Use for Daft (Parquet, single)
            hits = daft.read_parquet("hits.parquet")
            hits = hits.with_column("EventTime", col("EventTime").cast(daft.DataType.timestamp("s")))
            hits = hits.with_column("EventDate", col("EventDate").cast(daft.DataType.date()))
            hits = hits.with_column("URL", col("URL").decode("utf-8"))
            hits = hits.with_column("Title", col("Title").decode("utf-8"))
            hits = hits.with_column("Referer", col("Referer").decode("utf-8"))
            hits = hits.with_column("MobilePhoneModel", col("MobilePhoneModel").decode("utf-8"))
            hits = hits.with_column("SearchPhrase", col("SearchPhrase").decode("utf-8"))

        result = None

        if "lambda" in query:
            result = query["lambda"]()
        else:
            result = daft.sql(query["sql"])

        result.collect()

        if "extra_api" in query:
            result = query["extra_api"](result)

        run_time = timeit.default_timer() - start

        return run_time
    except Exception as e:
        print(f"Error executing query {query_idx+1}: {str(e)[:100]}", file=sys.stderr)
        traceback.print_exc()
        return None

if __name__ == "__main__":
    import sys
    query_idx = int(sys.argv[1]) - 1
    query = queries[query_idx]

    times = []
    for i in range(3):
        elapsed = run_single_query(query, i)
        times.append(f"{elapsed}" if elapsed else "")

    print(','.join(times))