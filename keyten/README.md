# Keyten

This entry uses Keyten's Python dataframe API and durable native columnar
storage. Run `./benchmark.sh` from this directory on Ubuntu 24.04 or newer.
The installer pins the engine version. Loading streams the single source
Parquet file into native storage without sorting or manual indexes.

`queries.sql` contains the 43 dataframe expressions, one per line. Source
timestamps remain integer seconds and dates remain integer days since the
Unix epoch; expression helpers implement the SQL temporal operations.

The loopback HTTP server shares the engine's worker pool across requests.
The client times the complete request and response, including query planning,
execution, and JSON serialization of every output value. No query results
are cached. The standard driver restarts the server and clears the OS page
cache before each query's first execution, then runs two hot executions.
The health endpoint does not open the dataset.

`data-size` reports all native storage files, including statistics and indexes.
The original downloaded Parquet file is not part of the stored database.
