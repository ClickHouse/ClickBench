# intent-gizmosql

A fork of GizmoSQL v1.38.0 (a Flight SQL server embedding DuckDB) and of its embedded DuckDB
v1.5.5, with server and engine changes:

- GizmoSQL: https://github.com/bddppqs/intent-gizmosql, tag `v1.38.0-intent.8` (the release this entry installs, Linux
  amd64 and arm64); changes in its `CHANGELOG.md` and `CLICKBENCH-FORK.md`.
- DuckDB: https://github.com/bddppqs/intent-duckdb, tag `v1.5.5-intent.8`; changes in its `CLICKBENCH-FORK.md`.

The scripts are the upstream `gizmosql` entry's except: `install` (downloads the pinned release and checks it by
SHA-256), `query` (detects a failed run from the client's exit status and its own error lines, not from result rows),
`check` (`SELECT 1`), `util.sh` (the configuration below; start and stop waits bounded at 60 s by the clock) and `load`
(waits polled every 50 ms; the load settings below). The schema and the load SQL are upstream's.

Configuration: on machines with more than 64 CPUs, `util.sh` sets one DuckDB thread per two CPUs and allocator settings
for a large dedicated host; smaller machines run the defaults.

Load: on machines with more than 64 CPUs and one thread per core (as `lscpu` reports), the bulk insert runs with
`threads` set to the CPU count (DuckDB's default) and `zstd_bulk_write_compression_level = 13`; both end with the server
restart before the first query. Otherwise neither is set; with SMT the insert was slower with them.

Caches: for its lifetime the server keeps decoded string dictionaries, column-wide dictionaries, code translations and
their byte lengths, row-group metadata, string-filter outcomes per dictionary entry (and the segments they let a scan
skip) and optimized plans of repeated read-only statements. For a statement with a cached plan, the hash-aggregate state
is released on a background thread after its result is sent.

Storage: blocks are zstd level 9 with 64 or more threads, 3 otherwise; `zstd_block_compression_level` overrides it, and
`zstd_bulk_write_compression_level` does for a bulk insert's blocks.

The entry is `tuned: yes`: for the configuration and load settings above, engine thresholds and three
per-architecture build-time defaults (named in the fork documents), and because the changes were developed and
evaluated against the 43 ClickBench queries.

Both repositories keep their upstream licenses (DuckDB: MIT; GizmoSQL: Apache-2.0).
