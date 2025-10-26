#!/usr/bin/env python3

import duckdb
import timeit
import sys
import os
import subprocess

with open('queries.sql', 'r') as file:
    for query in file:
        # Flush OS page cache before first run of each query
        subprocess.run(['sync'], check=True)
        subprocess.run(['sudo', 'tee', '/proc/sys/vm/drop_caches'], input=b'3', check=True, stdout=subprocess.DEVNULL)

        print(query)

        start = timeit.default_timer()
        con = duckdb.connect(':memory:')
        # disable preservation of insertion order
        con.execute("SET preserve_insertion_order = false;")
        con.execute(open("create.sql").read())
        con.execute(open("load.sql").read())
        print("Load time: {}", round(timeit.default_timer() - start, 3))

        for try_num in range(3):
            results = con.sql(query).fetchall()
            end = timeit.default_timer()
            print(round(end - start, 3))
            del results
            start = timeit.default_timer()
