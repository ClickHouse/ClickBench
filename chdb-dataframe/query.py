#!/usr/bin/env python3

import pandas as pd
import timeit
import datetime
import json
import chdb

start = timeit.default_timer()
hits = pd.read_parquet("hits.parquet")
end = timeit.default_timer()
load_time = end - start

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

queries_times = []
for q in queries:
    times = []
    for _ in range(3):
        start = timeit.default_timer()
        result = chdb.query(q, "Null")
        end = timeit.default_timer()
        times.append(end - start)
    queries_times.append(times)

result_json = {
    "system": "chDB (DataFrame)",
    "date": datetime.date.today().strftime("%Y-%m-%d"),
    "machine": "c6a.metal, 500gb gp2",
    "cluster_size": 1,
    "comment": "",
    "tags": [
        "C++",
        "column-oriented",
        "embedded",
        "stateless",
        "serverless",
        "dataframe",
        "ClickHouse derivative",
    ],
    "load_time": 0,
    "data_size": int(dataframe_size),
    "result": queries_times,
}

# if cpuinfo contains "AMD EPYC 9654" update machine and write result into results/epyc-9654.json
if "AMD EPYC 9654" in open("/proc/cpuinfo").read():
    result_json["machine"] = "EPYC 9654, 384G"
    with open("results/epyc-9654.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
else:
    # write result into results/c6a.metal.json
    with open("results/c6a.metal.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
