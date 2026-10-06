# intent-gizmosql

A fork of GizmoSQL v1.38.0 (a Flight SQL server embedding DuckDB) and of its embedded DuckDB
v1.5.5, with server and engine changes:

- GizmoSQL: https://github.com/bddppqs/intent-gizmosql, tag `v1.38.0-intent.5` (the release this entry installs: portable Linux amd64 and
  arm64 builds); changes in its `CHANGELOG.md` and `CLICKBENCH-FORK.md`.
- DuckDB: https://github.com/bddppqs/intent-duckdb, tag `v1.5.5-intent.5`; changes in its `CLICKBENCH-FORK.md`.

The scripts are the upstream `gizmosql` entry's except `install`, `query`, `util.sh` and `check`: `install` downloads the
pinned release zip and verifies it and both binaries by SHA-256, `query` runs the release's `gizmosql_client`, `util.sh`
applies the configuration below, and `check` runs `SELECT 1`. The schema and load path are upstream's.

Configuration: on machines with more than 64 CPUs `util.sh` sets one DuckDB thread per two CPUs and allocator settings
for a large dedicated host; smaller machines run the defaults.

Caches: for its lifetime the server keeps decoded DICT_FSST dictionaries, column-wide string dictionaries, stored code
translations, row-group metadata, string-filter outcomes per dictionary entry (and the segments they let a scan
skip) and optimized plans of repeated read-only statements. For a statement with a cached plan, the hash-aggregate state is released on a background thread after
its result is sent.

Storage: blocks are zstd-compressed at level 9 with 64 or more threads and 3 otherwise; `zstd_block_compression_level`
overrides it.

The entry is `tuned: yes`: for the configuration above, for engine thresholds and three per-architecture build-time
defaults (named in the fork documents), and because the changes were developed against the 43 ClickBench queries.

Both repositories keep their upstream licenses (DuckDB: MIT; GizmoSQL: Apache-2.0).
