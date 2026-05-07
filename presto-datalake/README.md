## Presto against the public S3 dataset

Same setup as `presto/`, but the parquet file lives on the public
`clickhouse-public-datasets` S3 bucket and is fetched on demand.

Presto's S3 reader signs every request, so it cannot talk to the public
bucket without an AWS account. The benchmark exposes the bucket as a
local filesystem with `s3fs-fuse` (`-o public_bucket=1`) and points the
Hive connector at the FUSE mount. Every read translates to an HTTP GET
against S3 (cached in `/tmp/s3fs-cache`).

`run.sh` enables `offset_clause_enabled` so the OFFSET-bearing queries
(Q39-Q43) succeed.
