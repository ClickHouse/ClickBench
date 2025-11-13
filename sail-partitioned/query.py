#!/usr/bin/env python3

from pysail.spark import SparkConnectServer
from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import timeit
import psutil
import sys
import re

query = sys.stdin.read()
# Replace \1 to $1 because spark recognizes only this pattern style (in query 28)
query = re.sub(r"""(REGEXP_REPLACE\(.*?,\s*('[^']*')\s*,\s*)('1')""", r"\1'$1'", query)
print(query)

import os
os.environ["SAIL_PARQUET__BINARY_AS_STRING"] = "true"
os.environ["SAIL_PARQUET__REORDER_FILTERS"] = "true"
os.environ["SAIL_OPTIMIZER__ENABLE_JOIN_REORDER"] = "true"

server = SparkConnectServer()
server.start()
_, port = server.listening_address

spark = SparkSession.builder.remote(f"sc://localhost:{port}").getOrCreate()

df = spark.read.parquet("partitioned")
df.createOrReplaceTempView("hits")

for try_num in range(3):
    try:
        start = timeit.default_timer()
        result = spark.sql(query)
        res = result.toPandas()
        end = timeit.default_timer()
        if try_num == 0:
            print(res)
        print("Time: ", round(end - start, 3))
    except Exception as e:
        print(e)
        print("Failure!")

spark.stop()
