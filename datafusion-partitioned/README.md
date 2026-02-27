# DataFusion

Partitioned (100-file) Parquet dataset

## Cookbook: Generate benchmark results

Follow instructions in the [datafusion](../datafusion/README.md) directory.

### Known Issues

1. DataFusion follows the SQL standard with case-sensitive identifiers, so all column names in `queries.sql` use double-quoted literals (e.g. `EventTime` -> `"EventTime"`).

2. You must set the `('binary_as_string' 'true')` due to an incorrect logical type
annotation in the partitioned files. See [Issue#7](https://github.com/ClickHouse/ClickBench/issues/7)

## Generate full human-readable results (for debugging)

1. Install/build `datafusion-cli`.

2. Download the parquet files:

```
seq 0 99 | xargs -P100 -I{} bash -c 'wget --directory-prefix partitioned --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
```

3. Run the queries: `datafusion-cli -f create.sql -f queries.sql` or `PATH="$(pwd)/arrow-datafusion/target/release:$PATH" ./run.sh`.
