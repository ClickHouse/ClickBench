## Trino against the public S3 dataset

Same setup as `trino/`, but the parquet file lives on the public
`clickhouse-public-datasets` S3 bucket and is fetched on demand instead
of being downloaded up front.

This measures the same thing as `clickhouse-datalake` (query latency over
a remote, on-demand parquet file); nothing is materialised on local disk
except the file metastore.
