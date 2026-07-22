# Spice.ai OSS (Parquet, partitioned)

[Spice.ai OSS](https://github.com/spiceai/spiceai) is a portable, single-binary
runtime built on Apache DataFusion that federates and accelerates SQL queries
across databases, data warehouses, and data lakes. This entry benchmarks the
runtime querying the 100-file partitioned `hits_{0..99}.parquet` dataset
directly through its file connector — no acceleration, no data loading; the
files are scanned in place as a single table. See `spiceai-parquet` for the
single-file variant and `spiceai-cayenne` for the same runtime with its
Cayenne acceleration engine.

Notes:

- Spice's file connector registers a dataset from either a single file or a
  directory (globbing it for files matching `file_format`); a literal glob
  path like `hits_*.parquet` is not expanded. `./load` therefore symlinks
  the downloaded `hits_*.parquet` partitions into a `data/` subdirectory,
  and `spicepod.yaml` registers `file:data` with `file_format: parquet`.
- The source parquet stores `EventDate` as an integer (days since epoch);
  the queries referencing `EventDate` wrap it as
  `to_timestamp("EventDate" * 86400)`. `queries.sql` is identical to the
  `spiceai-parquet` and `spiceai-cayenne` entries'.
- The SQL results cache (enabled by default in Spice) is disabled in
  `spicepod.yaml` per the benchmark caching rules.

Run `./benchmark.sh` on a fresh Ubuntu VM (see `lib/benchmark-common.sh` for
the flow), or use the repo's `run-benchmark.sh` automation.
