## Apache Hive on a single Parquet file

This setup runs Apache Hive 4 inside Docker, configured with:
- HiveServer2 and an embedded Derby metastore in a single container, and
- Tez as the execution engine (the upstream default for Hive 4),

so the entire benchmark reproduces on a single VM with nothing beyond
Docker installed.

The ClickBench `hits.parquet` file stores `EventTime`, `ClientEventTime`
and `LocalEventTime` as Unix-epoch `BIGINT` values, and `EventDate` as a
`INT` count of days since 1970-01-01. `create.sql` registers the parquet
file as an external table (`hits_raw`) and then exposes a `hits` view
that converts those columns to `TIMESTAMP` and `DATE`, so `queries.sql`
matches the canonical ClickBench query text.

The `results/20130923/` directory contains historical 100M-row and
10M-row results from 2013; the current run targets the standard 100M-row
ClickBench dataset.
