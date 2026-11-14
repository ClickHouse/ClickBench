"""
The PySpark session shared by load.py and query.py, and the registration of
the bluesky table (ddl.sql) in the session catalog. The default catalog is in
memory, so every session registers the table again over its Parquet files in
the bluesky directory.
"""

import os

import psutil
from pyspark.sql import SparkSession

TABLE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bluesky")


def create_session(app_name):
    # The JVM heap must be set explicitly (the default is 1 GB), as in the
    # main ClickBench entry: 70% of the available memory.
    ram = int(round(psutil.virtual_memory().available / (1024 ** 2) * 0.7))
    return (
        SparkSession
        .builder
        .appName(app_name)
        .master("local[*]")
        .config("spark.driver.memory", f"{ram}m")
        .getOrCreate()
    )


def register_table(spark):
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ddl.sql")) as f:
        ddl = f.read().strip().rstrip(";").format(location=TABLE_DIR)
    spark.sql(ddl)
