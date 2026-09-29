# chDB 26.7.3 vs 26.9.0 diagnostic

This temporary, **do-not-merge** system isolates the `c6a.large` regression
observed in PR #2294.

`chdb-diagnostic-a` and `chdb-diagnostic-b` run the same experiment in
opposite orders. Each replica loads data with chDB core 26.7.3, 26.9.0 using
the default `max_insert_threads`, and 26.9.0 using
`max_insert_threads = 1`. Copies of the default layouts are then queried by
both core versions.

Queries 13, 17, 24, 26, 32, and 40--42 run the full matrix with
`max_threads = 1` and `2`. Other queries run only the current configuration
(26.9.0 data, 26.9.0 runtime, two threads), so the normal ClickBench result
remains parseable. Extra measurements are emitted as `DIAG_LOAD` and
`DIAG_QUERY` JSON lines at the end of the benchmark log.
