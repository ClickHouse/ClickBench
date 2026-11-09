Experimental DuckDB plug-in for MariaDB, see
- https://github.com/MariaDB/duckdb-engine
- https://mariadb.org/mariadb-duckdb-a-new-playground-for-analytics-a-first-look-at-the-new-storage-engine/

The install script uses MariaDB 11.4.13 from archive.mariadb.org and the plugin package from
- https://github.com/drrtuy/duckdb-engine/releases/tag/v2.0.1-duckdb-fork (sha256 pinned in `install`)

The plugin embeds DuckDB from https://github.com/mariadb-AlekseiBukhalov/duckdb, branch `clickbench-perf-main`
(commit 5406f514e6): upstream DuckDB main of 2026-11-03 plus seven changes to the engine, written by the
author of this entry. They are a regexp rewrite rule, a key filter pushed into the scan for `GROUP BY ... LIMIT` without `ORDER BY`,
removal of constant `GROUP BY` keys, an integer fast path for aggregation, `LPAD`/`RPAD` for ASCII input,
faster ICU date parts, and `contains` on compressed dictionary strings. They were written while looking at
ClickBench query shapes. They are plan-shape and data-type rules (for example a trailing `.*$` in a regexp,
an integer first group key, row-count thresholds). They do not match on table or column names or on whole query text (the regexp rule looks at the shape of the
pattern, like DuckDB's existing regexp rules), and keep no state between queries. Server settings are in `install` (memory limit scaled to RAM,
`plugin-maturity=alpha`, `duckdb-allow-run-in-duckdb=ON`); no other server settings.
