#!/usr/bin/env python3

import timeit
import psutil
from chdb import dbapi

con = dbapi.connect(path=".clickbench")
cur = con.cursor()


print("Loading the data")
start = timeit.default_timer()
cur.execute(open("create.sql").read())
cur.execute(open("insert.sql").read())
end = timeit.default_timer()

print("Total time to load")
print(end - start)

cur.close()
con.close()
