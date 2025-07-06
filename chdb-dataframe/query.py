#!/usr/bin/env python3

import pandas as pd
import timeit
import datetime
import json
import chdb

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
start = timeit.default_timer()
for col in hits.columns:
    if hits[col].dtype == "O":
        hits[col] = hits[col].astype(str)

print("Dataframe(numpy) normalization time:", timeit.default_timer() - start)

queries = []
with open("queries.sql") as f:
    queries = f.readlines()

queries_times = []

# conn = chdb.connect("./tmp?verbose&log-level=test")
conn = chdb.connect("./tmp")
i = 0
for q in queries:
    i += 1
    times = []
    for _ in range(3):
        start = timeit.default_timer()
        result = conn.query(q, "Null")
        end = timeit.default_timer()
        times.append(round(end - start, 3))
    print(f"Q{i}: ", times)
    queries_times.append(times)

result_json = {
    "system": "chDB (DataFrame)",
    "date": datetime.date.today().strftime("%Y-%m-%d"),
    "machine": "c6a.metal",
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
    with open("results/epyc-9654-2.2.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
else:
    # write result into results/c6a.metal.json
    with open("results/c6a.metal.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
