#!/usr/bin/env python3

"""
Spark + Apache Gluten using the ClickHouse backend ('ch'). Gluten loads
libch.so (Kyligence's ClickHouse fork, built as a library) into the Spark JVM
and runs the columnar physical plan natively.

Reads SQL on stdin, runs it once, prints the result on stdout and the runtime
in fractional seconds as the LAST line on stderr.

Note: Keep in sync with spark-*/query.py (see README-accelerators.md for details).
"""

from pyspark.sql import SparkSession
import pyspark.sql.functions as F

import os
import psutil
import sys
import timeit


query = sys.stdin.read()
print(query)

# The ClickHouse engine does nearly all of the work off-heap, and each task gets
# off_heap / cores of it as its memory limit, so give it three quarters.
ram = int(round(psutil.virtual_memory().available / (1024 ** 2) * 0.7))
heap = ram // 4
off_heap = ram - heap
print(f"SparkSession will use {heap} MB of heap and {off_heap} MB of off-heap memory (total {ram} MB)")

libch = os.path.abspath("libch.so")

# libch.so must be preloaded into the JVM, as Gluten's own launcher does
# (ep/build-clickhouse/src/resources/bin/gluten.sh). It uses initial-exec TLS,
# which a lazy dlopen cannot place ("cannot allocate memory in static TLS
# block"), and its jemalloc must replace malloc for the whole process. In
# local[*] mode the driver is the executor, and pyspark starts its JVM with a
# copy of os.environ, so setting it here covers the JVM (not this Python
# process, which is already running).
os.environ["LD_PRELOAD"] = libch

builder = (
    SparkSession
    .builder
    .appName("ClickBench")
    .config("spark.driver", "local[*]") # To ensure using all cores
    .config("spark.driver.memory", f"{heap}m")
    .config("spark.sql.parquet.binaryAsString", True) # Treat binary as string to get correct length calculations and text results

    # Additional Gluten configuration
    # The CH backend registers Delta Lake data sources at startup, but Gluten
    # marks delta-spark as `provided`, so put it on the classpath ourselves.
    .config("spark.jars", "gluten.jar,delta-spark.jar,delta-storage.jar")
    .config("spark.driver.extraClassPath", "gluten.jar:delta-spark.jar:delta-storage.jar")
    .config("spark.plugins", "org.apache.gluten.GlutenPlugin")
    .config("spark.shuffle.manager", "org.apache.spark.shuffle.sort.ColumnarShuffleManager")
    .config("spark.memory.offHeap.enabled", "true")
    .config("spark.memory.offHeap.size", f"{off_heap}m")
    .config("spark.driver.extraJavaOptions", "-Dio.netty.tryReflectionSetAccessible=true")

    # ClickHouse backend
    .config("spark.gluten.sql.columnar.backend.lib", "ch")
    .config("spark.gluten.sql.columnar.libpath", libch)
    .config("spark.executorEnv.LD_PRELOAD", libch)
    # The CH backend has no native plan validator (its doValidate throws), so
    # with validation on, every operator falls back to vanilla Spark. Gluten's
    # own CH benchmarks and test suites turn it off.
    .config("spark.gluten.sql.enable.native.validation", "false")
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
