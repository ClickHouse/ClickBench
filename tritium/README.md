# tritium

tritium is a query engine, a personal research project. The source is not public; the binaries are released at
https://github.com/xmaton/tritium-release under a license that allows benchmarking and publishing the results.

## How to run it

- `install` downloads the binary and checks its SHA-256.
- `start` runs `tritium` and registers `hits.parquet` as a table available for queries. `tables.sql` declares the
  types of the `EventDate` and `EventTime` columns.
- `query` sends a query over HTTP and reports the time.
- The server is restarted and the caches are dropped before every query's first run.
