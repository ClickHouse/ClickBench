#!/usr/bin/env python3

"""
Spark + Apache Gluten using the ClickHouse backend ('ch'). The CH backend
loads libch.so (a fork of ClickHouse v23.1) into the Spark executor JVM
and runs the columnar physical plan natively.

Note: Keep in sync with spark-*/query.py (see README-accelerators.md for details).
"""

import os
import sys
import timeit

import psutil
from pyspark.sql import SparkSession
import pyspark.sql.functions as F


query = sys.stdin.read()
print(query)

# Calculate available memory to configure SparkSession (in MB).
# The CH backend runs off-heap (via JNI into libch.so), so split available
# memory between Spark's JVM heap and the off-heap pool the same way the
# Velox backend does.
ram = int(round(psutil.virtual_memory().available / (1024 ** 2) * 0.7))
heap = ram // 2
off_heap = ram - heap
print(f"SparkSession will use {heap} MB of heap and {off_heap} MB of off-heap memory (total {ram} MB)")

builder = (
    SparkSession
    .builder
    .appName("ClickBench")
    .config("spark.driver", "local[*]")
    .config("spark.driver.memory", f"{heap}m")
    .config("spark.sql.parquet.binaryAsString", True)

    # Gluten + ClickHouse backend configuration
    .config("spark.jars", "gluten.jar")
    .config("spark.driver.extraClassPath", "gluten.jar")
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin")
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager")
    .config("spark.gluten.sql.columnar.backend.lib", "ch")
    .config("spark.gluten.sql.columnar.libpath", os.path.abspath("libch.so"))
    .config("spark.memory.offHeap.enabled", "true")
    .config("spark.memory.offHeap.size", f"{off_heap}m")
    .config("spark.driver.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true")
)

spark = builder.getOrCreate()

df = spark.read.parquet("hits.parquet")
df = df.withColumn("EventTime", F.col("EventTime").cast("timestamp"))
df = df.withColumn("EventDate", F.date_add(F.lit("1970-01-01"), F.col("EventDate")))
df.createOrReplaceTempView("hits")

for try_num in range(3):
    try:
        start = timeit.default_timer()
        result = spark.sql(query)
        result.show(100)
        end = timeit.default_timer()
        print("Time: ", end - start)
    except Exception as e:
        print(e)
        print("Failure!")
