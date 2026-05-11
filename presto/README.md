## Presto on a single Parquet file

Same shape as `trino/`: the Hive connector backed by the file-based
metastore, with the parquet file mounted into the Presto Docker container.
No Hive Metastore Service, no Hadoop, no S3 needed.

Differences from `trino/`:

- The connector name is `hive-hadoop2`.
- `CREATE SCHEMA` may not specify a `WITH (location = ...)` clause.
- Presto's default 1 GB JVM heap is too small for ClickBench, so the
  startup script writes a custom `jvm.config`/`config.properties`.
- The Presto CLI is not bundled with the server image, so the script
  downloads `presto-cli-<version>-executable.jar` from GitHub releases.

The `hits` view applies the same `EventTime`/`EventDate` conversions used
in the Trino entry, so `queries.sql` is the canonical ClickBench query
text.
