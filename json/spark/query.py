#!/usr/bin/env python3

"""
Reads SQL on stdin, runs it once via PySpark, prints the result on stdout
and the runtime in fractional seconds as the LAST line on stderr.
As in the main ClickBench Spark entry, the time is measured from the
submission of the query to the end of printing its result, without the
start of the session.
"""

import sys
import timeit

from session import create_session, register_table

query = sys.stdin.read().strip().rstrip(";")

spark = create_session("JSONBench")
register_table(spark)

try:
    start = timeit.default_timer()
    result = spark.sql(query)
    result.show(100, truncate=False)
    end = timeit.default_timer()
    elapsed = end - start
    print(f"Time: {elapsed}")
    print(f"{elapsed:.6f}", file=sys.stderr)
except Exception as e:
    print(e, file=sys.stderr)
    print("Failure!", file=sys.stderr)
    sys.exit(1)
