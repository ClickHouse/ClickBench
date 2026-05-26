# ZigHouse

ZigHouse is an experimental analytical database binary written in Zig.

This ClickBench entry uses the published Linux x86_64 benchmark binary from:

https://github.com/donge/zighouse/releases/tag/v0.1.0-clickbench

The binary imports the ClickBench Parquet dataset into a local column-oriented store and runs the 43 ClickBench queries with its native engine.

## Running

From this directory inside the ClickBench repository:

```sh
./benchmark.sh
```

The benchmark script downloads `hits.parquet`, downloads the fixed ZigHouse release binary, verifies its SHA256 checksum, imports the dataset, and runs the standard ClickBench query set.

## Notes

The included AWS result was produced on `c6i.4xlarge` in AWS China. `c6a.4xlarge` was not available in the AWS China regions used for this run.
