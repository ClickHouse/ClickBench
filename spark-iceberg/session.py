"""The SparkSession of the Iceberg entry, shared by load.py and query.py.

The Iceberg REST catalog is registered as `lake` and made the default one,
with the `clickbench` namespace as the current database, so the queries refer
to the table simply as `hits`. The settings come from lib/iceberg/env.sh.
"""

import glob
import os

import psutil
from pyspark.sql import SparkSession


def session():
    env = os.environ
    # Calculate available memory to configure the SparkSession (in MB), as the
    # other Spark entries do; the default of 1 GB does not fit the dataset.
    ram = int(round(psutil.virtual_memory().available / (1024 ** 2) * 0.7))
    catalog = "spark.sql.catalog.lake"
    spark = (
        SparkSession
        .builder
        .appName("ClickBench")
        .master("local[*]")
        .config("spark.driver.memory", f"{ram}m")
        .config("spark.jars", ",".join(sorted(glob.glob(os.path.join(os.path.dirname(__file__), "jars", "*.jar")))))
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
        .config(catalog, "org.apache.iceberg.spark.SparkCatalog")
        .config(f"{catalog}.type", "rest")
        .config(f"{catalog}.uri", env["LAKE_CATALOG_URI"])
        .config(f"{catalog}.warehouse", env["LAKE_WAREHOUSE"])
        .config(f"{catalog}.credential", f"{env['LAKE_CLIENT_ID']}:{env['LAKE_CLIENT_SECRET']}")
        .config(f"{catalog}.oauth2-server-uri", env["LAKE_OAUTH_URI"])
        .config(f"{catalog}.scope", "catalog")
        .config(f"{catalog}.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
        .config(f"{catalog}.s3.endpoint", env["LAKE_S3_ENDPOINT"])
        .config(f"{catalog}.s3.path-style-access", env["LAKE_S3_PATH_STYLE"])
        .config(f"{catalog}.client.region", env["AWS_REGION"])
        .config("spark.sql.defaultCatalog", "lake")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("ERROR")
    return spark
