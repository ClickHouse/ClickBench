# intent-gizmosql

A released fork of GizmoSQL v1.38.0 (a server embedding DuckDB) whose embedded
DuckDB v1.5.5 carries a small series of engine changes:

- GizmoSQL: https://github.com/bddppqs/intent-gizmosql, tag `v1.38.0-clickbench.1` (the release this entry installs).
- DuckDB: https://github.com/bddppqs/intent-duckdb, tag `v1.5.5-clickbench.1` (changes documented in that
  repository's `CLICKBENCH-FORK.md`: batched RE2 character-class runs, CountZeros builtins with
  selection-fed HyperLogLog, an evictable decoded-dictionary cache with admission back-off, and
  a cross-request memo of literal `regexp_replace` domains over dictionary vectors).

The scripts in this directory are the upstream `gizmosql` entry's, unchanged, except:

- `install`, which downloads the pinned release zip and verifies its SHA-256 instead of running
  the vendor's network installer;
- `query`, whose failure check only looks at the client's own diagnostics (exit code, `Error:`
  lines) and no longer at result rows: a URL or title containing the word "error" in a result
  window over tied counts (e.g. Q39's `LIMIT 10 OFFSET 1000`) turned a valid run into a null
  timing in the upstream version.

The server runs with its default configuration, the upstream schema (`create.sql`) and the
upstream load path; there is no extra index, pre-aggregation or query-specific configuration.

Disclosure: the DuckDB changes were developed and evaluated against the 43 ClickBench queries on
the ClickBench dataset. They are general engine mechanisms that do not change query results, the
storage format or the SQL surface. Because of that development history the entry is labelled
`tuned: yes` at the maintainers' request; the ClickBench maintainers decide its final name and
labels.

Both repositories keep their upstream licenses (DuckDB: MIT; GizmoSQL: Apache-2.0).
