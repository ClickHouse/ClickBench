# Apache Spark

Apache Spark 4 (the latest 4.x release from PyPI, `pyspark`) in local mode,
with the `VARIANT` data type of Spark 4.

- The table `bluesky` has a single `VARIANT` column `data` and is stored in
  Parquet files in the directory `bluesky` (see `ddl.sql`). The default session
  catalog is in memory, so every PySpark session (`load.py`, and `query.py` for
  every query) registers the table over the files again.
- `load.py` reads the `.json.gz` files as text, parses every line with
  `try_parse_json` and writes the table. The few invalid lines of the dataset
  (documents longer than 64 KiB split into two lines) become `NULL` and are
  skipped. With fewer files than cores, the lines are repartitioned to parse
  them on all cores (a `.json.gz` file is read by a single task).
- The queries access the paths with `variant_get`. Q2 uses the exact
  `count(DISTINCT ...)`.
- As in the main ClickBench Spark entry, every query runs in a new PySpark
  session; the time is measured from the submission of the query to the end of
  printing its result, without the start of the session. The only setting is
  the JVM heap size (`spark.driver.memory`, 70% of the available memory), a
  prerequisite for running the benchmark.
