# Doris Parquet

1. Launch a local Doris cluster with 1 FE and 1 BE on a c6a.4xlarge instance with 500 GB gp2 storage.
2. Execute benchmark.sh, which will:
    1. Download 100 hints Parquet files locally
    2. Run create.sql to create test tables
    3. Execute run.sh to start the benchmark

## References

- [clickhouse-parquet](../clickhouse-parquet/)
- [duckdb-parquet](../duckdb-parquet/)
