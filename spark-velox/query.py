#!/usr/bin/env python3

"""
Spark + Velox via Apache Gluten. Reads SQL on stdin, runs it once via
PySpark, prints the result on stdout, and the runtime in fractional
seconds as the LAST line on stderr.

The Gluten plugin offloads the physical plan from Spark Catalyst to
Velox (a C++ vectorised execution engine). spark-gluten/query.py uses
Gluten with whichever backend the bundle was built with; this file
pins the backend to velox explicitly via
spark.gluten.sql.columnar.backend.lib.

Note: Keep in sync with spark-*/query.py (see spark/README-accelerators.md).
"""

from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import psutil
import sys
import timeit


query = sys.stdin.read()
print(query)

# Velox runs off-heap, so split available memory between Spark's JVM
# heap and Gluten's native off-heap pool.
ram = int(round(psutil.virtual_memory().available / (1024 ** 2) * 0.7))
heap = ram // 2
off_heap = ram - heap
print(f"SparkSession will use {heap} MB of heap and {off_heap} MB of off-heap memory (total {ram} MB)")

builder = (
    SparkSession
    .builder
    .appName("ClickBench")
    .config("spark.driver", "local[*]")  # Use all cores
    .config("spark.driver.memory", f"{heap}m")
    .config("spark.sql.parquet.binaryAsString", True)  # Correct length / text result

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

try:
    start = timeit.default_timer()
    result = spark.sql(query)
    result.show(100)
    end = timeit.default_timer()
    elapsed = end - start
    print(f"Time: {elapsed}")
    print(f"{elapsed:.6f}", file=sys.stderr)
except Exception as e:
    print(e, file=sys.stderr)
    print("Failure!", file=sys.stderr)
    sys.exit(1)
