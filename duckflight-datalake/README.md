# Duckflight: single-file S3 data lake

Run `./benchmark.sh` from this directory. This entry keeps a persistent DuckDB
view over the region-local public `hits_compatible/hits.parquet` object, queried
through the Rust Arrow client. There is no local download or table ingestion.
`parquet_metadata_cache=true` matches DuckDB's lake runner. The load phase creates
the view/macro, verifies 99,997,497 rows and starts the host. Data size is the
remote object's actual Content-Length (14,779,976,446 bytes for the measured run).

Each standard hook independently selects this storage mode and this directory's
state; it does not require manually exported mode variables. The dataset helper
selects the regional mirror automatically and honors explicit source/region
and `CLICKBENCH_DATASET_BUCKET` overrides.

Use `./baseline`, `./validate-native`, `./summarize` and `./stop` from this directory.
See [the shared runner documentation](../duckflight/README.md) for installation,
timing, validation and result-conversion details. This entry is separate from
native storage and the 100-file partitioned layout.

The 2026-10-21 result was validated on the full dataset. Throughput was explicitly
skipped for the latency comparison and remains null in the submitted result.
