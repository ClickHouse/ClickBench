## Trino on a single Parquet file

This setup uses Trino's Hive connector backed by:
- a file-based metastore (no external Hive Metastore Service required), and
- the native local filesystem driver (`fs.native-local.enabled=true`),

so the entire benchmark can be reproduced on a single VM with nothing
beyond Docker installed.

The ClickBench `hits.parquet` file stores `EventTime`, `ClientEventTime`
and `LocalEventTime` as Unix-epoch `BIGINT` values, and `EventDate` as a
`UINT16` count of days since 1970-01-01. `create.sql` registers the
parquet file as a raw external table (`hits_raw`) and then exposes a
`hits` view that converts those columns to `TIMESTAMP` and `DATE`, so
`queries.sql` matches the canonical ClickBench query text.
