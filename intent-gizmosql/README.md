# intent-gizmosql

A fork of GizmoSQL v1.38.0 (a Flight SQL server embedding DuckDB) and of its embedded DuckDB
v1.5.5, with server and engine changes:

- GizmoSQL: https://github.com/bddppqs/intent-gizmosql, tag `v1.38.0-intent.2` (the release this entry installs: portable Linux amd64 and
  arm64 builds); changes in its `CHANGELOG.md` and `CLICKBENCH-FORK.md`.
- DuckDB: https://github.com/bddppqs/intent-duckdb, tag `v1.5.5-intent.2`; changes in its `CLICKBENCH-FORK.md`.

The scripts are the upstream `gizmosql` entry's except: `install` downloads the pinned release zip and verifies it and
both binaries by SHA-256; `query` runs the release's `gizmosql_client`, which sends each query as one request, and
detects a failed run from the client's exit status and its own error lines, not from result rows; `util.sh` applies the
configuration below. The schema and load path are upstream's, with no extra index, pre-aggregation or query-specific
setting.

Configuration: on machines with more than 64 CPUs `util.sh` sets one DuckDB thread per two CPUs and allocator settings
for a large dedicated host, as tuning for this benchmark and not suggested defaults; smaller machines run the defaults.

Caches: for its lifetime the server keeps what queries build: decoded DICT_FSST dictionaries, column-wide string
dictionaries, string-filter outcomes per dictionary entry (and the segments they let a scan skip) and optimized plans of
repeated read-only statements. All but the plans are used at or just above the scan; every run still scans, filters and
aggregates. None holds a query result, and the restart before every cold run clears them. Among the server changes, for
a statement with a cached plan the hash-aggregate state is released on a background thread after its result is sent.

Storage: database files created at the latest storage version, as the entry's are, store zstd-compressed blocks under
storage version `0x40000001`, which upstream DuckDB does not open.
The zstd level is 9 when DuckDB runs 64 or more threads and 3 otherwise, and the setting
`zstd_block_compression_level` overrides it.

The entry is `tuned: yes`: for the configuration above, for a few engine thresholds and three per-architecture
build-time defaults (on for x86-64, off for arm64; named in the fork documents), and because the changes were developed
and evaluated against the 43 ClickBench queries on the ClickBench dataset. The ClickBench maintainers decide its final
name and labels.

Both repositories keep their upstream licenses (DuckDB: MIT; GizmoSQL: Apache-2.0).
