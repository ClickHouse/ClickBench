#!/usr/bin/env python3
"""Creates the Iceberg table through the REST catalog and writes the dataset
into it with a single INSERT with the default settings."""

import os

from session import session

spark = session()
here = os.path.dirname(os.path.abspath(__file__))

# The source: the downloaded Parquet files. A temporary view rather than
# parquet.`path` in SQL, which would be looked up in the default catalog first.
spark.read.parquet(os.path.join(here, "hits_*.parquet")).createOrReplaceTempView("hits_parquet")

for name in ("create.sql", "insert.sql"):
    with open(os.path.join(here, name)) as f:
        spark.sql(f.read().strip().rstrip(";"))
spark.stop()
