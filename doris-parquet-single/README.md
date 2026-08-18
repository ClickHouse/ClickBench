# Doris Parquet (single)

Like [doris-parquet](../doris-parquet/), but over the single `hits.parquet`
file instead of the 100 partitioned files: a local Doris cluster with 1 FE and
1 BE queries the file in place through the `local()` table-valued function.

## References

- [doris-parquet](../doris-parquet/)
- [clickhouse-parquet](../clickhouse-parquet/)
- [duckdb-parquet](../duckdb-parquet/)
