#!/usr/bin/env python3

import duckdb
import timeit
import psutil

con = duckdb.connect(database="my-db.duckdb", read_only=False)


# enable the progress bar
con.execute('PRAGMA enable_progress_bar')
con.execute('PRAGMA enable_print_progress_bar;')
# enable parallel CSV loading
con.execute("SET experimental_parallel_csv=true")
# disable preservation of insertion order
con.execute("SET preserve_insertion_order=false")

# perform the actual load
print("Will load the data")
start = timeit.default_timer()
con.execute(open("create.sql").read())
con.execute("COPY hits FROM 'hits.csv'")
end = timeit.default_timer()
print(end - start)
