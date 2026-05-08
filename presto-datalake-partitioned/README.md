## Presto against the public S3 dataset (100 partitions)

Same setup as `presto-datalake/`, but the external table points at the
100-file `athena_partitioned` directory in the public
`clickhouse-public-datasets` bucket. Data is fetched on demand via the
s3fs-fuse mount.
