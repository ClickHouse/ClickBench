#!/usr/bin/env python3

import duckdb
import timeit
import sys

query = sys.stdin.read()
print(f"running {query}", file=sys.stderr)

con = duckdb.connect(database="md:clickbench", read_only=False)
print('[', end='')

for try_num in range(3):
    if try_num > 0:
        print(',', end='')

    try:
        start = timeit.default_timer()
        results = con.sql(query).fetchall()
        end = timeit.default_timer()
        print(round(end - start, 3), end='')
    except Exception as e:
        print('null', end='')
        print(f"query <{query.strip()}> errored out on attempt <{try_num+1}>: {e}", file=sys.stderr)

print(']')
