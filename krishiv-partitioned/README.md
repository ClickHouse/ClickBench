# Krishiv

[Krishiv](https://github.com/KrishivAI/krishiv-engine) is an Apache-2.0
Spark-compatible SQL and DataFrame engine written in Rust, without the JVM. It
runs embedded in Python (`pip install krishiv`).

The entry keeps one Krishiv session alive in a small FastAPI server (`server.py`),
as an application embedding the engine would, and queries the Parquet files in
place: `load` only registers the `hits` view, with `EventTime` and `EventDate`
converted by `timestamp_seconds` and `date_from_unix_date`. The partitioned files
store strings as `BINARY`, so the session sets `spark.sql.parquet.binaryAsString`.
The timing covers the full result, materialized as an Arrow table.

The queries are the Spark SQL ones (`spark/queries.sql`). Differences from
ClickHouse that come from Spark semantics: `length` counts characters, `.` in
regular expressions does not match a newline, and `AVG(UserID)` is the true mean
(ClickHouse wraps the `Int64` sum).
