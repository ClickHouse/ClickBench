#!/usr/bin/env python3

"""
Spark + Velox via Apache Gluten. The Velox backend executes the columnar
plan natively in C++; the Gluten plugin handles the offload from Spark's
Catalyst plan.

Note: Keep in sync with spark-*/query.py (see README-accelerators.md for details).
"""

from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import psutil
import sys
import timeit


query = sys.stdin.read()
print(query)

# Calculate available memory to configurate SparkSession (in MB).
# Velox runs off-heap, so split the available memory between Spark's JVM
# heap and Gluten's native off-heap memory pool.
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

    # Gluten + Velox configuration
    .config("spark.jars", "gluten.jar")
    .config("spark.driver.extraClassPath", "gluten.jar")
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin")
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager")
    .config("spark.gluten.sql.columnar.backend.lib", "velox")
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
