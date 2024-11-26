#!/usr/bin/env python3

import duckdb
import timeit
import sys
import os

con = duckdb.connect(read_only=False)

# enable the progress bar
con.execute('PRAGMA enable_progress_bar;')
con.execute('PRAGMA enable_print_progress_bar;')
# disable preservation of insertion order
con.execute("SET preserve_insertion_order = false;")

# perform the actual load
print("Will load the data")
start = timeit.default_timer()
con.execute(open("create.sql").read())
con.execute("COPY hits FROM 'hits.csv';")
end = timeit.default_timer()
print(end - start)

with open('queries.sql', 'r') as file:
    for query in file:
        os.system("sync")
        os.system("echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null")

        print(query)

        for try_num in range(3):
            start = timeit.default_timer()
            results = con.sql(query).fetchall()
            end = timeit.default_timer()
            print(end - start)
            del results
