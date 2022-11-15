#!/usr/bin/env python3

import duckdb
import timeit
import psutil
import sys

query = sys.stdin.read()
print(query)

con = duckdb.connect(database="my-db.duckdb", read_only=False)
# enable parquet metadata cache
con.execute("PRAGMA enable_object_cache")

for try_num in range(3):
    start = timeit.default_timer()
    results = con.execute(query).fetchall()
    end = timeit.default_timer()
    print(end - start)
