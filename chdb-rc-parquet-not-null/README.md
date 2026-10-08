Diagnostic copy of `chdb-parquet-partitioned/` for a chdb-core release candidate.
Not meant to be merged.

- `install` pins chdb-core to the same `CORE_TAG` used by the native RC tests.
- `create.sql` defines an explicit NOT NULL schema over `hits_*.parquet` with
  `ENGINE = File(Parquet, ...)`, matching the ClickHouse Local benchmark shape.
- `query` creates that table outside the measured query interval.
- `queries.sql` addresses the explicit `hits` table instead of inferring a schema
  from the parquet glob for every query.
