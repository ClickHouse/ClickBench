# Manticore Search

The latest Manticore Search from its official APT repository, with the default
configuration of the package.

The table (`ddl.sql`) is a real-time table with a single `json` attribute, `data`, that
holds the whole document. Manticore stores JSON attributes in a binary form that keeps the
complete document (nesting, arrays, key order), and `SELECT data` returns the original
document, so `retains_structure` is `yes`. There are no indexes on the JSON paths.

The data is loaded with the HTTP `/bulk` endpoint (`bulk-load.py`, four files at a time,
two concurrent requests of about 4 MB per file), each line embedded unchanged into the
`data` attribute, dropping the few lines that are not valid JSON. Then the RAM chunk is
written to disk (`FLUSH RAMCHUNK`) and the disk chunks are merged with
`OPTIMIZE TABLE ... OPTION sync=1` (what the automatic optimization does in the
background, with the same default cutoff), so that the merges do not run during the
queries.

The queries (`queries.sql`) are SQL over the MySQL protocol; the runtime is the `time` of
`SHOW META`, measured by the server. The query cache of Manticore only keeps the results
of full-text searches, so it does not apply here.

- Q1 and Q2 have `OPTION max_matches=10000`: Manticore keeps at most `max_matches` (by
  default 1000) groups, and the number of collections may grow over that with the size.
- Q2: `COUNT(DISTINCT data.did)` returns 0 for a JSON attribute, the distinct count is over
  an alias of the same value. It is approximate by default (HyperLogLog), and exact with
  `OPTION distinct_precision_threshold=0`, which the query uses; at 1m it gives the
  exact counts. The documentation warns that the counts may still be inaccurate for a
  real-time table with several disk chunks.
- Q4 runs with the default `max_matches`: with `ORDER BY MIN(...) ASC`, the groups that
  are dropped from the bounded set of groups cannot be in the result, so it is exact.
- Q5 is null: Manticore does not allow expressions over aggregate functions
  (`MAX(...) - MIN(...)` is a syntax error, and `b - a` over the aliases of the aggregates
  is computed per row, giving 0), and has no subqueries.
