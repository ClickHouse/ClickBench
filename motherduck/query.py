#!/usr/bin/env python3

import duckdb
import timeit
import psutil
import sys

query = sys.stdin.read()
print(query)

con = duckdb.connect('md:')
con = duckdb.connect(database="md:ClickBench", read_only=False)
for try_num in range(3):
    start = timeit.default_timer()
    results = con.sql(query).fetchall()
    end = timeit.default_timer()
    print(round(end - start, 3))
    del results
