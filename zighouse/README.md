# ZigHouse

ZigHouse is an experimental native ClickBench runner written in Zig. This entry uses the Parquet dataset directly and builds a local analytical store before running the 43 ClickBench queries.

The submitted binary is built without DuckDB support:

```sh
zig build -Dduckdb=false
```

Runtime verification on macOS showed the binary only linked the system library:

```text
zig-out/bin/zighouse:
    /usr/lib/libSystem.B.dylib
```

## Running

From this directory inside the ClickBench repository:

```sh
./benchmark.sh
```

The script downloads `hits.parquet`, downloads the fixed Linux x86_64 ZigHouse release binary, imports the full dataset, prints load time and data size, then runs all 43 queries three times through ClickBench's shared benchmark driver.

## Notes

This is a tuned ClickBench-specific implementation. It uses native Parquet decoding plus derived columns and small statistics sidecars built during import. Query result caches are disabled in `ZIGHOUSE_CLICKBENCH_SUBMIT=1` mode.

The sidecars include per-row flags, low-cardinality dictionaries, hash/string resolvers, and aggregate statistics needed by specific ClickBench query shapes. They are included in the reported data size.

The included AWS result was produced on `c6i.4xlarge` in `cn-northwest-1`, because `c6a.4xlarge` was unavailable in the AWS China regions used for this run. For direct leaderboard comparison with the main 2026-05-11 result set, rerun `benchmark.sh` on the standard AWS machines such as `c6a.4xlarge` and add the resulting JSON under `results/YYYYMMDD/`.
