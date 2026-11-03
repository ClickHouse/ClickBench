#!/usr/bin/env python3

"""
Usage: load.py <file with the list of .json.gz files>

Creates the bluesky table (a VARIANT column in Parquet files, see ddl.sql)
and loads the files into it: every line is parsed with try_parse_json.

A few lines in the dataset are not valid JSON (documents of more than 64 KiB
that were cut into two lines): try_parse_json returns NULL for them, and they
are skipped.
"""

import os
import shutil
import sys

from session import TABLE_DIR, create_session, register_table

with open(sys.argv[1]) as f:
    files = [line.strip() for line in f if line.strip()]

shutil.rmtree(TABLE_DIR, ignore_errors=True)
os.makedirs(TABLE_DIR)

spark = create_session("JSONBench load")
register_table(spark)

# A .json.gz file is not splittable, and Spark reads it in a single task: with
# fewer files than cores, distribute the lines to parse them on all cores.
lines = spark.read.text(files)
if len(files) < spark.sparkContext.defaultParallelism:
    lines = lines.repartition(spark.sparkContext.defaultParallelism)

lines.selectExpr("try_parse_json(value) AS data").where("data IS NOT NULL").write.insertInto("bluesky")

spark.stop()
