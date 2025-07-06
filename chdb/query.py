#!/usr/bin/env python3

import timeit
import sys
import os
import glob
from chdb import dbapi

def main():
    query = sys.stdin.read()
    print(query)

    con = dbapi.connect(path=".clickbench")
    cur = con.cursor()

    for try_num in range(3):
        start = timeit.default_timer()
        cur._cursor.execute(query)
        end = timeit.default_timer()
        print(round(end - start, 3))

    cur.close()
    con.close()

if __name__ == "__main__":
    main()
