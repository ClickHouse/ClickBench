#!/usr/bin/env python3

"""
Note: Keep in sync with spark-*/query.sh (see README-accelerators.md for details)
"""

from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import psutil
import re
import sys
import timeit

query = sys.stdin.read()
# Replace \1 to $1 because spark recognizes only this pattern style (in query 28)
query = re.sub(r"""(REGEXP_REPLACE\(.*?,\s*('[^']*')\s*,\s*)('1')""", r"\1'$1'", query)
print(query)

# Calculate available memory to configurate SparkSession
ram = int(round(psutil.virtual_memory().available / (1024 ** 3) * 0.7))
print(f"SparkSession will use {ram} GB of memory")

spark = (
    SparkSession
    .builder
    .appName("ClickBench")
    .config("spark.driver", "local[*]") # To ensure using all cores
    .config("spark.driver.memory", f"{ram}g") # Set amount of memory SparkSession can use
    .config("spark.sql.parquet.binaryAsString", True) # Treat binary as string to get correct length calculations and text results
    .getOrCreate()
)

df = spark.read.parquet("hits.parquet")
# Do casting before creating the view so no need to change to unreadable integer dates in SQL
df = df.withColumn("EventTime", F.col("EventTime").cast("timestamp"))
df = df.withColumn("EventDate", F.date_add(F.lit("1970-01-01"), F.col("EventDate")))
df.createOrReplaceTempView("hits")

for try_num in range(3):
    try:
        start = timeit.default_timer()
        result = spark.sql(query)
        result.show(100) # some queries should return more than 20 rows which is the default show limit
        end = timeit.default_timer()
        print("Time: ", end - start)
    except Exception as e:
        print(e);
        print("Failure!")
