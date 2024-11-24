#!/usr/bin/env python3

from pyspark.sql import SparkSession

import timeit
import psutil
import sys

query = sys.stdin.read()
print(query)

spark = SparkSession.builder.appName("ClickBench").getOrCreate()
df = spark.read.parquet("hits.parquet")
df.createOrReplaceTempView("hits")

for try_num in range(3):
    try:
        start = timeit.default_timer()
        result = spark.sql(query)
        result.show()
        end = timeit.default_timer()
        print("Time: ", end - start)
    except Exception as e:
        print(e);
        print("Failure!")
