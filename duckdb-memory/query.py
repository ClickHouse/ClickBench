#!/usr/bin/env python3

import duckdb
import timeit
import sys
import os

with open('queries.sql', 'r') as file:
    for query in file:
        con = duckdb.connect(':memory:')

        # enable the progress bar
        con.execute('PRAGMA enable_progress_bar;')
        con.execute('PRAGMA enable_print_progress_bar;')
        # disable preservation of insertion order
        con.execute("SET preserve_insertion_order = false;")

        print(query)

        for try_num in range(3):
            start = timeit.default_timer()

            if try_num == 0:
                con.execute(open("create.sql").read())
                con.execute(open("load.sql").read())
                print("Load time: {}", round(timeit.default_timer() - start, 3))

            results = con.sql(query).fetchall()
            end = timeit.default_timer()
            print(round(end - start, 3))
            del results
