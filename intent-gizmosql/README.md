# intent-gizmosql

A fork of GizmoSQL v1.38.0 (a Flight SQL server embedding DuckDB) and of its embedded DuckDB
v1.5.5, with server and engine changes:

- GizmoSQL: https://github.com/bddppqs/intent-gizmosql, tag `v1.38.0-intent.3` (the release this entry installs: portable Linux amd64 and
  arm64 builds); changes in its `CHANGELOG.md` and `CLICKBENCH-FORK.md`.
- DuckDB: https://github.com/bddppqs/intent-duckdb, tag `v1.5.5-intent.3`; changes in its `CLICKBENCH-FORK.md`.

The scripts are the upstream `gizmosql` entry's except: `install` downloads the pinned release zip and verifies it and
both binaries by SHA-256; `query` runs the release's `gizmosql_client`, which sends each query as one request, and
detects a failed run from the client's exit status and its own error lines, not from result rows; `start`, `check` and
`util.sh` are described below. The schema and load path are upstream's, with no extra index, pre-aggregation or
query-specific setting.

Configuration: on machines with more than 64 CPUs `util.sh` sets one DuckDB thread per two CPUs and allocator settings
for a large dedicated host, as tuning for this benchmark and not suggested defaults; smaller machines run the defaults.
`start` also reads the server and client binaries and the server's shared libraries into the page cache, and `check`
runs `SELECT 1`; neither reads the database file.

Caches: for its lifetime the server keeps decoded DICT_FSST dictionaries, column-wide string dictionaries and the
stored code translations it has read, string-filter outcomes per dictionary entry (and the segments they let a scan
skip), and optimized plans of repeated read-only statements. None holds a query result; every run still scans, filters
and aggregates, and the restart before every cold run clears them. For a statement with a cached plan, the
hash-aggregate state is released on a background thread after its result is sent.

Storage: database files created at the latest storage version, as the entry's are, use storage version `0x40000002`,
which upstream DuckDB does not open. Blocks are zstd-compressed (level 9 with 64 or more threads, otherwise 3;
`zstd_block_compression_level` overrides it); at each checkpoint the engine stores large string columns' dictionary codes
apart from the strings, with a column-wide numbering; string statistics also keep the smallest non-empty value.

The entry is `tuned: yes`: for the configuration above, for a few engine thresholds and three per-architecture
build-time defaults (on for x86-64, off for arm64; named in the fork documents), and because the changes were developed
and evaluated against the 43 ClickBench queries on the ClickBench dataset. The ClickBench maintainers decide its final
name and labels.

Both repositories keep their upstream licenses (DuckDB: MIT; GizmoSQL: Apache-2.0).
