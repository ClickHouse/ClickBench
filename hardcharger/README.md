# Hardcharger

[Hardcharger](https://github.com/gizmodata/hardcharger) is a SQL server that runs DuckDB 2.0 and
speaks [Warp SQL](https://github.com/gizmodata/warp-sql), an HTTP protocol that returns query
results as Apache Arrow. It is the successor to GizmoSQL and is open source (Apache 2.0).

The scripts follow the `gizmosql` entry:

- `install` runs Hardcharger's official one-line installer
  (`curl https://install.hardcharger.gizmodata.com | sh`), defaulting to the official
  `2.0.0` release. `HARDCHARGER_VERSION` can override that version; the installer verifies the
  release checksum.
- `start` runs `hardcharger-server` on `hits.db` with its defaults (all CPUs, DuckDB's default
  memory limit, no result cache) and `--storage-version latest`, as the `duckdb` and `gizmosql`
  entries do. It listens on 127.0.0.1:31337, plain HTTP.
- `load` creates the table and loads `hits.parquet` with the `duckdb` entry's `INSERT`, through the
  `hardcharger` client.
- `query` runs each query through the `hardcharger` client in a new process (sign in, a new
  session, the query, all rows back to the client) and reports the client's `.timer` "Run Time":
  from sending the query to receiving the last row of the result.
- The server is restarted, and the page cache dropped, before the first run of each query.
