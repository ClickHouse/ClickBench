#!/usr/bin/env python3

import chdb
import timeit
import psutil
import sys

query = sys.stdin.read()
print(query)

for try_num in range(3):
    start = timeit.default_timer()
    results = chdb.query(query).data()
    end = timeit.default_timer()
    print(end - start)
    del results
