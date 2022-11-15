#!/usr/bin/env python3

import duckdb
import timeit
import psutil

con = duckdb.connect(database="my-db.duckdb", read_only=False)

print("Set up a view over the Parquet files")

start = timeit.default_timer()
con.execute(open("create.sql").read())
end = timeit.default_timer()
print(end - start)
