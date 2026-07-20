# Spice.ai OSS (Parquet, single)

[Spice.ai OSS](https://github.com/spiceai/spiceai) is a portable, single-binary
runtime built on Apache DataFusion that federates and accelerates SQL queries
across databases, data warehouses, and data lakes. This entry benchmarks the
runtime querying `hits.parquet` directly through its file connector — no
acceleration, no data loading; the single parquet file is scanned in place.
See `spiceai-parquet-partitioned` for the 100-file variant and
`spiceai-cayenne` for the same runtime with its Cayenne acceleration engine.

Notes:

- `spicepod.yaml` takes the place of `create.sql`: it registers the parquet
  file as a dataset. The source parquet stores `EventDate` as an integer
  (days since epoch); the queries referencing `EventDate` wrap it as
  `to_timestamp("EventDate" * 86400)`. `queries.sql` is identical to the
  `spiceai-cayenne` entry's.
- The SQL results cache (enabled by default in Spice) is disabled in
  `spicepod.yaml` per the benchmark caching rules.

Run `./benchmark.sh` on a fresh Ubuntu VM (see `lib/benchmark-common.sh` for
the flow), or use the repo's `run-benchmark.sh` automation.
