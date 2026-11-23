# StarRocks (Parquet, single)

Runs a local StarRocks cluster with 1 FE and 1 BE and queries the single
`hits.parquet` file in place through a view over the `FILES()` table function
(`file://` protocol), without loading it into StarRocks storage.

## References

- [starrocks](../starrocks/)
- [doris-parquet](../doris-parquet/)
- [clickhouse-parquet](../clickhouse-parquet/)
