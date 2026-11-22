# Hardcharger (Parquet, partitioned)

[Hardcharger](https://github.com/gizmodata/hardcharger) on the 100 partitioned Parquet files in place:
the `hardcharger` entry's server and client, with the `duckdb-parquet-partitioned` entry's view.
Hardcharger 2.14.0 runs on [Hardcharger Engine](https://github.com/gizmodata/hardcharger-engine) v2.0.1, a fork
derived from DuckDB 2.0.1 and modified for performance
([changes and benchmark notes](https://github.com/gizmodata/hardcharger-engine/blob/v2.0.1/docs/optimizations.md)).

- `install`, `start`, `stop`, `check` and `util.sh` are the `hardcharger` entry's: the official installer
  (default `2.14.0`, `HARDCHARGER_VERSION` overrides it), `hardcharger-server` on `hits.db` with its defaults
  on 127.0.0.1:31337, plain HTTP. The server is restarted, and the page cache dropped, before the first run of
  each query.
- `load` creates `hits.db` with `create.sql`: a view over `hits_*.parquet` (`binary_as_string`, `EventDate`
  as a date) and the `toDateTime` macro, as in `duckdb-parquet-partitioned`. Nothing is loaded.
- `query` runs each query through the `hardcharger` client in a new process, after
  `SET parquet_metadata_cache = true` (as `duckdb-parquet-partitioned` does), and reports the client's
  `.timer` "Run Time" of the query: from sending it to receiving the last row of the result.
- `queries.sql` is `duckdb-parquet-partitioned`'s; `data-size` is the size of the Parquet files.
