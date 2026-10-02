## Trino against the public S3 dataset (100 partitions)

Same setup as `trino-datalake/`, but the external table points at the
100-file `athena_partitioned` directory in the public `clickhouse-public-datasets`
bucket, fetched on demand instead of being downloaded up front.
