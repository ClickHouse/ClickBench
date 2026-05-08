## Trino against the public S3 dataset

Same setup as `trino/`, but the parquet file lives on the public
`clickhouse-public-datasets` S3 bucket and is fetched on demand instead
of being downloaded up front.

Trino's native S3 reader signs every request, so it cannot talk to the
public bucket without an AWS account. The benchmark therefore exposes
the bucket as a local filesystem with `s3fs-fuse` (`-o public_bucket=1`)
and points the Hive connector at the FUSE mount. The Hive connector's
parquet reader then issues normal POSIX reads, but every read translates
to an HTTP GET against S3.

This means the benchmark measures the same things as `clickhouse-datalake`
(query latency over a remote, on-demand parquet file), with the caveat
that data goes through s3fs's userspace cache rather than Trino's native
S3 splitter. Nothing is materialised on local disk except the s3fs
read-through cache under `/tmp/s3fs-cache`.
