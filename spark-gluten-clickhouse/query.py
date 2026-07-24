#!/usr/bin/env python3

"""
Spark + Apache Gluten using the ClickHouse backend ('ch'). The CH backend
loads libch.so (a fork of ClickHouse v23.1) into the Spark executor JVM and
runs the columnar physical plan natively.

Reads SQL on stdin, runs it once, prints the result on stdout and the runtime
in fractional seconds as the LAST line on stderr.

Note: Keep in sync with spark-*/query.py (see README-accelerators.md for details).
"""

import faulthandler
import os
import signal
import sys
import threading
import time
import timeit

import psutil
from pyspark.sql import SparkSession
import pyspark.sql.functions as F


# --- Diagnostic scaffolding (temporary) --------------------------------------
# The CH backend is built + loaded remotely on c6a.metal and cannot be
# reproduced on the (aarch64) dev box, so each iteration costs a ~1h build.
# The harness sends query stdout to /dev/null and only surfaces stderr when a
# query *exits non-zero*; a hang therefore produces no output and burns the
# full 10h job timeout. These helpers make a hang fail fast and loud instead:
#   * STEP markers on stderr pinpoint how far we got before wedging.
#   * A watchdog forces a JVM thread dump (SIGQUIT) then kills the JVM so the
#     captured-stderr pipe closes and the invocation exits non-zero.
#   * A sentinel file short-circuits the remaining tries/queries once one hang
#     is observed, so a fully-wedged backend costs one timeout, not 43x3.
# Remove once queries run cleanly.
# Generous per-query cap: any real ClickBench query finishes in well under this
# on c6a.metal, and the sentinel means a total hang costs only ONE timeout (not
# 43x3), so a large value is safe and won't false-trip a slow-but-valid query.
QUERY_TIMEOUT = int(os.environ.get("QUERY_TIMEOUT", "600"))
HANG_SENTINEL = "query_hang.sentinel"


def mark(msg):
    print(f"=== STEP: {msg} ===", file=sys.stderr, flush=True)


def _dump_and_die():
    print(
        f"\n=== WATCHDOG: query.py exceeded {QUERY_TIMEOUT}s; dumping stacks ===",
        file=sys.stderr,
        flush=True,
    )
    jvms = []
    try:
        for child in psutil.Process().children(recursive=True):
            try:
                if "java" in child.name().lower():
                    jvms.append(child)
                    print(
                        f"=== sending SIGQUIT to JVM pid {child.pid} for thread dump ===",
                        file=sys.stderr,
                        flush=True,
                    )
                    child.send_signal(signal.SIGQUIT)
            except Exception as exc:  # noqa: BLE001
                print(f"watchdog: {exc}", file=sys.stderr, flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"watchdog: could not enumerate children: {exc}", file=sys.stderr, flush=True)

    time.sleep(10)  # let the JVM flush its thread dump to our stderr

    print("=== Python stacks ===", file=sys.stderr, flush=True)
    faulthandler.dump_traceback(file=sys.stderr)
    sys.stderr.flush()

    # Kill the JVM so the pipe the harness reads from (2>&1) closes and the
    # command substitution capturing our stderr returns instead of blocking.
    for child in jvms:
        try:
            child.kill()
        except Exception:  # noqa: BLE001
            pass

    try:
        open(HANG_SENTINEL, "w").close()
    except Exception:  # noqa: BLE001
        pass
    os._exit(1)


if os.path.exists(HANG_SENTINEL):
    print(
        "=== a prior query hung (see earlier thread dump); fast-failing ===",
        file=sys.stderr,
        flush=True,
    )
    sys.exit(1)

watchdog = threading.Timer(QUERY_TIMEOUT, _dump_and_die)
watchdog.daemon = True
watchdog.start()
# -----------------------------------------------------------------------------


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

# Gluten's CH backend loads libch.so into the JVM lazily via JNI (System.load,
# from CHListenerApi.initialize). libch.so carries initial-exec-model TLS (from
# its statically linked deps), and glibc sizes the static TLS block at process
# startup, leaving only a small surplus — so a lazy dlopen from the running JVM
# fails with:
#   java.lang.UnsatisfiedLinkError: libch.so: cannot allocate memory in static
#   TLS block
# Gluten's docs suggest LD_PRELOAD=<libch.so>, but preloading forces libch.so's
# global constructors and (statically linked) allocator onto the whole JVM from
# process start, which deadlocked JVM startup here (query never returned). The
# cleaner fix is glibc's `rtld.optional_static_tls` tunable: it enlarges the
# per-thread static-TLS surplus reserved at startup, so the *lazy* System.load
# succeeds without preloading anything. It must be in the environment before
# the dynamic loader runs, i.e. before the JVM starts; setting it here does not
# affect this already-running Python process, but pyspark's launcher copies
# os.environ into the JVM it spawns, so the JVM starts with the enlarged
# surplus.
#
# Value matters: an over-large surplus makes glibc *segfault* every
# multi-threaded process at thread creation (measured threshold ~7 MiB on
# glibc 2.43; 8 MiB crashes, 6 MiB is fine). A 16 MiB attempt crashed pyspark's
# own launcher JVM (`org.apache.spark.launcher.Main`), which surfaced as
# `spark-class: line 97: CMD: bad array subscript` +
# `[JAVA_GATEWAY_EXITED] Java gateway process exited before sending its port
# number`. 2 MiB is ~1260x the failing glibc default (1664 B) — comfortably
# more than libch.so's real IE-TLS footprint — while staying well under the
# crash threshold on both glibc 2.39 (noble) and 2.43.
_TLS_SURPLUS = "glibc.rtld.optional_static_tls=2097152"
os.environ["GLIBC_TUNABLES"] = _TLS_SURPLUS

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

    # Cluster-mode equivalent of the GLIBC_TUNABLES above: a no-op in local[*]
    # (the driver JVM is the executor and already inherits os.environ) but kept
    # so real executors get the same enlarged static-TLS surplus.
    .config("spark.executorEnv.GLIBC_TUNABLES", _TLS_SURPLUS)
)

mark("building SparkSession (JVM launch + libch.so load)")
spark = builder.getOrCreate()

mark("SparkSession ready; reading hits.parquet")
df = spark.read.parquet("hits.parquet")
df = df.withColumn("EventTime", F.col("EventTime").cast("timestamp"))
df = df.withColumn("EventDate", F.date_add(F.lit("1970-01-01"), F.col("EventDate")))
df.createOrReplaceTempView("hits")

mark("temp view created; executing query")
try:
    start = timeit.default_timer()
    result = spark.sql(query)
    result.show(100)
    end = timeit.default_timer()
    elapsed = end - start
    mark("query complete")
    print(f"Time: {elapsed}")
    print(f"{elapsed:.6f}", file=sys.stderr)
except Exception as e:
    print(e, file=sys.stderr)
    print("Failure!", file=sys.stderr)
    sys.exit(1)
finally:
    watchdog.cancel()
