# ZigHouse

ZigHouse is an experimental analytical database binary written in Zig.

This ClickBench entry uses the published Linux x86_64 benchmark binary from:

https://github.com/donge/zighouse/releases/tag/v0.2.0-clickbench

The binary imports the ClickBench Parquet dataset into a local column-oriented store and runs the 43 ClickBench queries with its native engine.

## Running

From this directory inside the ClickBench repository:

```sh
./benchmark.sh
```

The benchmark script downloads `hits.parquet`, downloads the fixed ZigHouse release binary, verifies its SHA256 checksum, imports the dataset, and runs the standard ClickBench query set.

## Two execution paths

- **ClickBench optimization profile** — fast paths hand-tuned to the shapes of the 43 ClickBench queries. Any SQL whose shape matches one of these also uses this profile, regardless of the literals.
- **Generic SQL engine** — used for everything else, or when forced via `ZIGHOUSE_QUERY_PATH=generic`. `compare` mode runs both paths and checks byte-identical output.

`generic-smoke.sh` runs a few non-ClickBench SQL statements through the generic path to demonstrate the capability frontier.

## Notes

The included AWS result was produced on `c6i.4xlarge` in AWS China. `c6a.4xlarge` was not available in the AWS China regions used for this run.
