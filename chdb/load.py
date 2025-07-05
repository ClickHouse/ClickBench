#!/usr/bin/env python3

from chdb import dbapi

con = dbapi.connect(path=".clickbench")
cur = con.cursor()

cur.execute(open("create.sql").read())
cur.execute(open("insert.sql").read())

cur.close()
con.close()
