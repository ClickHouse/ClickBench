# Duckflight: partitioned S3 data lake

Run `./benchmark.sh` from this directory. This entry keeps a persistent DuckDB
view over the region-local public
`hits_compatible/athena_partitioned/hits_*.parquet` objects, queried through Rust
the Rust Arrow client. There is no local download or table ingestion.
`parquet_metadata_cache=true` and explicit anonymous S3 credentials/region match
DuckDB's partitioned lake runner. The load phase verifies 99,997,497 rows and
records all matching object names and their total bytes in `.state/storage.json`.
The measured source has 100 objects totaling 14,737,666,736 bytes.

Each standard hook independently selects this storage mode and this directory's
state; it does not require manually exported mode variables. The dataset helper
selects the regional mirror automatically and honors explicit source/region
and `CLICKBENCH_DATASET_BUCKET` overrides.

Use `./baseline`, `./validate-native`, `./summarize` and `./stop` from this directory.
See [the shared runner documentation](../duckflight/README.md) for installation,
timing, validation and result-conversion details. Keep this entry separate from
the single-file lake layout.

The 2026-10-21 result was validated on the full dataset. Throughput was explicitly
skipped for the latency comparison and remains null in the submitted result.
