# Duckflight

DuckDB 2.0.0 with the Duckflight extension (core-v0.1.14), queried using Apache
Arrow's Rust client 60.0.0. The extension contains a proprietary core.

Run `./benchmark.sh` on Ubuntu 24.04+ with sudo access. The installer downloads
the released DuckDB CLI and extension, installs Python dependencies, and builds
the Arrow client. Downloads and dependencies are pinned.

The client timer includes execution and fetching all results; connection,
authentication and CSV formatting are outside the timer. The shared ClickBench
driver restarts the server and clears OS caches before each cold run. Warm runs
retain the server. DuckDB uses default thread and memory settings.

The native entry loads `hits.parquet` into a table. `../duckflight-datalake` and
`../duckflight-datalake-partitioned` read the standard single-file and partitioned
S3 datasets through views. Run `./benchmark.sh` in the corresponding directory;
each entry has its own state and uses the shared regional dataset helper.

The 2026-10-21 results use c6a.4xlarge with 500 GB gp2 storage. Concurrent QPS is
unavailable: the native phase was aborted and the lake phases were skipped.
