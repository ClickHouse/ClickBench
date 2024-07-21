#!/usr/bin/env python3

import timeit
import sys
import os
import glob
from chdb import dbapi

def delete_table(pattern):
    matching_files = glob.glob(pattern)
    if matching_files:
        first_file = matching_files[0]
        os.remove(first_file)

def main():
    query = sys.stdin.read()
    print(query)

    delete_table('table.sql')
    con = dbapi.connect(path=".clickbench")
    cur = con.cursor()

    for try_num in range(3):
        delete_table('table.sql')
        start = timeit.default_timer()
        cur.execute(query)
        end = timeit.default_timer()
        print(end - start)

    cur.close()
    con.close()

if __name__ == "__main__":
    main()

