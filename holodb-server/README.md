HoloDb run as a server. The published image (`ghcr.io/evaluatedapplications/holodb`, tag in `bench.env`) serves the store from a bind-mounted directory; queries go over TLS from a small .NET client. The loader is the `EvaluatedApplications.HoloDb` package (version pinned in `bench.env`).

- `install` pulls the image and builds the client and loader.
- `load` writes the store from `hits.parquet`; `start` runs the container; `stop` stops it.
- `query` reads one statement on stdin, prints rows, and prints the elapsed seconds on the last stderr line. The timer covers `ExecuteAsync` (send, execute, receive, decode). Connection setup, the TLS handshake and printing the rows are outside it.
- `STRLEN(` is rewritten to `OCTET_LENGTH(` (same byte count; the standard name).
- The server is started with `--dialect extended` (the official queries use `LIMIT`, `DATE_TRUNC`, `REGEXP_REPLACE`), `--paged`, `--statement-seconds 600`, and a token file. The container runs with the .NET server GC (`DOTNET_gcServer=1`), and the image sets `DOTNET_TC_CallCountingDelayMs=0`. There are no other settings.

HoloDb builds some structures from the queries it sees: zone maps, per-column value counts (computed during the load), per-column match bits for text predicates such as `LIKE` and `OCTET_LENGTH` comparisons, and per-column order ranks (the sort position of each distinct value) used by `ORDER BY ... LIMIT`, `MIN` and `MAX`. They describe a column's values. The value counts are built by `load` and kept. The rest are built by queries and saved next to the table, and `stop` deletes them once the container is gone, so after a restart a query starts with only what `load` built; the second and third runs of a query use what its first run built. The store is created fresh by `load`.

HoloDb also keeps pre-aggregated data for every column. `load` builds it, and it is kept for the whole run:
- the exact totals of each numeric column: row count, sum, minimum and maximum;
- the value counts: the number of rows for each distinct value of a column, which is the result of `SELECT col, COUNT(*) FROM hits GROUP BY col`.

A query that this data covers is answered from it, without reading the rows of the table. Counting from 1 in `queries.sql`:
- Queries 1, 3, 4, 7 and 30 are answered from the column totals. `SUM(col + k)` is computed as `SUM(col) + k * COUNT(*)`.
- Queries 2, 5, 6, 8, 13, 16, 34, 35 and 36 are answered from the value counts. These are `COUNT(*)` with a single `col <> 0` or `col <> ''` filter, `COUNT(DISTINCT col)`, and `GROUP BY col` with `COUNT(*)`. A constant key (`GROUP BY 1, URL`) and keys of the form `col - k` next to `col` are dropped first.

Only these shapes take the shortcut. A filter such as `col <> 1`, or one more aggregate such as `SUM(IsRefresh)`, makes the same query scan the table. The other 29 queries scan and aggregate the data.

The entry is in the `joke` category, because the license of HoloDb forbids decompiling it, so nobody else can check how the engine gets its results.
