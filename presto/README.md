# Presto

Presto is a distributed SQL query engine for big data.
- [Github](https://github.com/prestodb/presto)
- [Homepage](https://prestodb.io)

The benchmarks are based on Presto version `0.287`.

We assume that a Presto cluster is already running. For more information, visit [Getting Started](https://prestodb.io/getting-started/).

----------
## Steps

1. Access the parquet file through this path: s3://clickhouse-public-datasets/hits_compatible/hits.parquet or just download the parquet file and upload it to an S3 Bucket yourself ex. s3://your-bucket/clickbench-parquet/hits/hits.parquet.
2. Create a new schema named `clickbench_parquet` in the Hive metastore (Hive catalog) and create the hits table in the new schema using the create.sql file. Modify the end of the table creation statement to use the parquet file on S3. 
```
WITH (
    format = 'PARQUET',
    external_location = 's3a://your-bucket/clickbench-parquet/hits/'
);
```
3. Connect to the Presto coordinator and run these commands: 
``` 
git clone https://github.com/ClickHouse/ClickBench
cd ClickBench/presto
chmod +x run.sh
./run.sh
```
