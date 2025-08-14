#!/usr/bin/env python3

"""
Note: Keep in sync with spark-*/query.py (see README-accelerators.md for details)

Current differences:
 - memory is split between heap (for Spark) and off-heap (for Gluten)
 - Gluten configuration is added to `SparkSession`
- debug mode is added
"""

from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import os
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
heap = ram // 2
off_heap = ram - heap
print(f"SparkSession will use {heap} GB of heap and {off_heap} GB of off-heap memory")

builder = (
    SparkSession
    .builder
    .appName("ClickBench")
    .config("spark.driver", "local[*]") # To ensure using all cores
    .config("spark.driver.memory", f"{heap}g") # Set amount of memory SparkSession can use
    .config("spark.sql.parquet.binaryAsString", True) # Treat binary as string to get correct length calculations and text results

    # Additional Gluten configuration
    .config("spark.jars", "gluten.jar")
    .config("spark.driver.extraClassPath", "gluten.jar")
    .config("spark.executor.extraClassPath", "gluten.jar")
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin")
    .config("spark.gluten.sql.columnar.backend.lib", "velox")
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager")
    .config("spark.memory.offHeap.enabled", "true")
    .config("spark.memory.offHeap.size", f"{off_heap}g")
)

# Even more Gluten configuration
if os.getenv("DEBUG") == "1":
    builder.config("spark.gluten.sql.columnar.backend.debug", "true")
    builder.config("spark.sql.debug.maxToStringFields", "10000")

spark = builder.getOrCreate()

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
        print(e)
        print("Failure!")
