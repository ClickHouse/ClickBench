# Spice.ai OSS (Cayenne)

[Spice.ai OSS](https://github.com/spiceai/spiceai) is a portable, single-binary
runtime built on Apache DataFusion that federates and accelerates SQL queries
across databases, data warehouses, and data lakes. This entry benchmarks its
native Cayenne acceleration engine: `./load` ingests `hits.parquet` into a
disk-backed Cayenne table (`acceleration: {engine: cayenne, mode: file}`), and
queries are served from that acceleration through the runtime's HTTP API.

Notes:

- `spicepod.yaml` takes the place of `create.sql`: it defines the dataset and
  its acceleration. The dataset keeps the source parquet schema, where
  `EventDate` is an integer (days since epoch); the queries referencing
  `EventDate` wrap it as `to_timestamp("EventDate" * 86400)`, matching how
  Spice's own benchmark suite runs ClickBench. Everything else in
  `queries.sql` is identical to the `datafusion` entry's.
- The SQL results cache (enabled by default in Spice) is disabled in
  `spicepod.yaml` per the benchmark caching rules.
- The acceleration persists across restarts and the runtime skips re-ingestion
  when the on-disk data is current, so the true-cold-run restart cycle serves
  disk-resident data like other durable systems.

Run `./benchmark.sh` on a fresh Ubuntu VM (see `lib/benchmark-common.sh` for
the flow), or use the repo's `run-benchmark.sh` automation.
