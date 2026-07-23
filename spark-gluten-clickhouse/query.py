#!/usr/bin/env python3

"""
Spark + Apache Gluten using the ClickHouse backend ('ch'). The CH backend
loads libch.so (a fork of ClickHouse v23.1) into the Spark executor JVM and
runs the columnar physical plan natively.

Reads SQL on stdin, runs it once, prints the result on stdout and the runtime
in fractional seconds as the LAST line on stderr.

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
    .config("spark.driver", "local[*]")  # To ensure using all cores
    .config("spark.driver.memory", f"{heap}m")
    .config("spark.sql.parquet.binaryAsString", True)  # Correct length/text results

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

    # Cluster-mode equivalent of the LD_PRELOAD below; a no-op in local[*] but
    # kept so the config is correct if this is ever run on real executors.
    .config("spark.executorEnv.LD_PRELOAD", os.path.abspath("libch.so"))
)

# Gluten's CH backend loads libch.so into the JVM via JNI (System.load). The
# library carries initial-exec-model TLS (from its statically linked deps), so
# a lazy dlopen from the already-running JVM fails with
#   java.lang.UnsatisfiedLinkError: libch.so: cannot allocate memory in static
#   TLS block
# because the static TLS block is sized at process startup. Gluten's docs work
# around this with spark.executorEnv.LD_PRELOAD=<libch.so>, but in local[*] mode
# the driver JVM *is* the executor and is launched (by pyspark below) before any
# Spark config is read, so executorEnv never applies. Instead, preload it via
# the driver JVM's environment: setting LD_PRELOAD here does not affect this
# already-started Python process, but pyspark's launcher copies os.environ into
# the JVM it spawns, so the JVM preloads libch.so at startup while the static
# TLS block still has room. System.load() then reuses the already-loaded lib.
os.environ["LD_PRELOAD"] = os.path.abspath("libch.so")

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
