# TimeFusion

[TimeFusion](https://github.com/monoscope-tech/timefusion) is a database for observability data (logs, traces, metrics), written in Rust on top of Apache DataFusion. It stores tables in Delta Lake format on S3-compatible object storage and speaks the PostgreSQL wire protocol.

How this entry works:

- TimeFusion only serves tables declared in YAML schema files compiled into the binary, so `install` builds it from source with `hits.yaml` added to `schemas/`. The table has no partitions (TimeFusion normally partitions by `project_id` and `date`) and is sorted by the same key as the primary key of the ClickHouse entry. There is no 16-bit integer type, so `SMALLINT` columns are `Int32`.
- Object storage is a local single-process [SeaweedFS](https://github.com/seaweedfs/seaweedfs) (`weed mini`) on the same machine. `data-size` reports the size of the bucket.
- `load` inserts the partitioned Parquet files one at a time through the `hits__bulk` alias, which commits directly to the Delta table, bypassing the write-ahead log and in-memory buffer used for streaming inserts. A single `INSERT` of the whole dataset is materialized in memory and runs out of it.
- For cold runs, `flush-caches` removes TimeFusion's persistent local disk cache in addition to the OS page cache. SeaweedFS is not restarted.
- The default limit of 90 seconds per statement is raised.
