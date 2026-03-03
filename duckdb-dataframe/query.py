#!/usr/bin/env python3

import pandas as pd
import timeit
import datetime
import subprocess
import duckdb

start = timeit.default_timer()
hits = pd.read_parquet("hits.parquet")
end = timeit.default_timer()
load_time = round(end - start, 3)
print(f"Load time: {load_time}")

dataframe_size = hits.memory_usage().sum()

# print("Dataframe(numpy) size:", dataframe_size, "bytes")

# fix some types
hits["EventTime"] = pd.to_datetime(hits["EventTime"], unit="s")
hits["EventDate"] = pd.to_datetime(hits["EventDate"], unit="D")

# fix all object columns to string
for col in hits.columns:
    if hits[col].dtype == "O":
        hits[col] = hits[col].astype(str)

queries = []
with open("queries.sql") as f:
    queries = f.readlines()

conn = duckdb.connect()
for q in queries:
    # Flush OS page cache before first run of each query
    subprocess.run(['sync'], check=True)
    subprocess.run(['sudo', 'tee', '/proc/sys/vm/drop_caches'], input=b'3', check=True, stdout=subprocess.DEVNULL)

    times = []
    for _ in range(3):
        start = timeit.default_timer()
        result = conn.execute(q).fetchall()
        end = timeit.default_timer()
        times.append(round(end - start, 3))
    print(times)
