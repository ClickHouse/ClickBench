# StarRocks (Parquet, partitioned)

Runs a local StarRocks cluster with 1 FE and 1 BE and queries the 100
`hits_{0..99}.parquet` files in place through a view over the `FILES()` table
function (`file://` protocol), without loading them into StarRocks storage.

## References

- [starrocks](../starrocks/)
- [doris-parquet](../doris-parquet/)
- [clickhouse-parquet-partitioned](../clickhouse-parquet-partitioned/)
