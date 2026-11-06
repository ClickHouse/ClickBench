#!/usr/bin/env python3
"""Reads SQL on stdin, runs it once via PySpark against the Iceberg table,
prints the result on stdout and the runtime in fractional seconds as the LAST
line on stderr."""

import sys
import timeit

from session import session

query = sys.stdin.read()
spark = session()
spark.sql("USE clickbench")

try:
    start = timeit.default_timer()
    result = spark.sql(query)
    result.show(100)  # some queries return more than 20 rows, the default show limit
    end = timeit.default_timer()
    print(f"{end - start:.6f}", file=sys.stderr)
except Exception as e:
    print(e, file=sys.stderr)
    print("Failure!", file=sys.stderr)
    sys.exit(1)
