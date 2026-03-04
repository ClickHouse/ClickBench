#!/usr/bin/env python3

import daft
import os
import sys
import timeit
import traceback
from daft import col, DataType

hits = None
current_dir = os.path.dirname(os.path.abspath(__file__))
query_idx = int(sys.argv[1]) - 1
is_single_mode = len(sys.argv) > 2 and sys.argv[2] == "single"
parquet_path = os.path.join(
    current_dir,
    "hits.parquet" if is_single_mode else "hits_*.parquet"
)

with open("queries.sql") as f:
    sql_list = [q.strip() for q in f.read().split(';') if q.strip()]

def run_single_query(sql, i):
    try:
        start = timeit.default_timer()

        global hits
        if hits is None:
            hits = daft.read_parquet(parquet_path)
            hits = hits.with_column("EventTime", col("EventTime").cast(DataType.timestamp("s")))
            hits = hits.with_column("EventDate", col("EventDate").cast(DataType.date()))
            hits = hits.with_column("URL", col("URL").decode("utf-8"))
            hits = hits.with_column("Title", col("Title").decode("utf-8"))
            hits = hits.with_column("Referer", col("Referer").decode("utf-8"))
            hits = hits.with_column("MobilePhoneModel", col("MobilePhoneModel").decode("utf-8"))
            hits = hits.with_column("SearchPhrase", col("SearchPhrase").decode("utf-8"))

        result = daft.sql(sql)
        result.collect()

        run_time = round(timeit.default_timer() - start, 3)
        return run_time
    except Exception as e:
        print(f"Error executing query {query_idx}: {str(e)[:100]}", file=sys.stderr)
        traceback.print_exc()
        return None

if __name__ == "__main__":
    sql = sql_list[query_idx]
    times = []
    for i in range(3):
        elapsed = run_single_query(sql, i)
        times.append(f"{elapsed}" if elapsed else "")
    print(','.join(times))
