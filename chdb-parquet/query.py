#!/usr/bin/env python3

import chdb
import timeit
import sys

query = sys.stdin.read()
print(query)

conn = chdb.connect()
for try_num in range(3):
    start = timeit.default_timer()
    conn.query(query, "Null")
    end = timeit.default_timer()
    print(end - start)

conn.close()
