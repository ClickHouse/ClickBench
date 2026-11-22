HoloDb run as a server. The published image (`ghcr.io/evaluatedapplications/holodb`, tag in `bench.env`) serves the store from a bind-mounted directory; queries go over TLS from a small .NET client. The loader is the `EvaluatedApplications.HoloDb` package (version pinned in `bench.env`). More about HoloDb: https://evaluatedapplications.github.io/holodb/

- `install` pulls the image and builds the client and loader.
- `load` writes the store from `hits.parquet`; `start` runs the container; `stop` stops it.
- `query` reads one statement on stdin, prints rows, and prints the elapsed seconds on the last stderr line. The timer covers `ExecuteAsync` (send, execute, receive, decode). Connection setup, the TLS handshake and printing the rows are outside it.
- `STRLEN(` is rewritten to `OCTET_LENGTH(` (same byte count; the standard name).
- The server is started with `--dialect extended` (the official queries use `LIMIT`, `DATE_TRUNC`, `REGEXP_REPLACE`), `--paged`, `--statement-seconds 600`, and a token file. The container runs with the .NET server GC (`DOTNET_gcServer=1`), and the image sets `DOTNET_TC_CallCountingDelayMs=0`. There are no other settings.
- The loader uses DuckDB (the `DuckDB.NET` package) only to read `hits.parquet` and hand the rows to HoloDb's bulk loader. No query runs on DuckDB, and the image contains no other database.

## What the engine keeps, and what answers a query

An earlier version of this README said that HoloDb's structures never hold a query's answer and that every statement scans and aggregates the data. That was wrong, and the rest of this section describes what actually happens.

HoloDb keeps the columns as the authoritative data, in its own typed storage, and derives other structures from them automatically. There is no setup step and nothing to configure. The name comes from one of those structures: per-row holographic encodings (vector-symbolic bind and bundle) that HoloDb derives for similarity search with `NEAREST`. None of the 43 queries uses them.

**Built by `load`, kept for the whole run.** The data size reported for this entry includes them (the value-count file is about 1.4 GB of the 31.6 GB).
- the exact totals of each numeric column: row count, sum, minimum and maximum (sums are exact, in 128-bit integers);
- the value counts: the number of rows for each distinct value of a column, which is the result of `SELECT col, COUNT(*) FROM hits GROUP BY col`;
- zone maps: the minimum and maximum of each block of 8,192 rows of an integer column, used to skip blocks.

When rows are inserted, updated or deleted, the engine updates these structures or drops them, so an answer taken from them is always exact.

**Built by queries.** Per-column match bits for text predicates such as `LIKE` and `OCTET_LENGTH` comparisons, and per-column order ranks (the sort position of each distinct value) used by `ORDER BY ... LIMIT`, `MIN` and `MAX`. They describe a column's values and are saved next to the table. `stop` deletes them once the container is gone, so after a restart a query starts with only what `load` built; the second and third runs of a query use what its first run built. The store is created fresh by `load`.

**Which queries are answered without reading the rows.** A query that the totals or the value counts cover is answered from them. Counting from 1 in `queries.sql`:
- Queries 1, 3, 4, 7 and 30 are answered from the column totals. `SUM(col + k)` is computed as `SUM(col) + k * COUNT(*)`.
- Queries 2, 5, 6, 8, 13, 16, 34, 35 and 36 are answered from the value counts. These are `COUNT(*)` with a single `col <> 0` or `col <> ''` filter, `COUNT(DISTINCT col)`, and `GROUP BY col` with `COUNT(*)`. A constant key (`GROUP BY 1, URL`) and keys of the form `col - k` next to `col` are dropped first.

This list is the one the reviewers of this entry found. The other 29 queries scan and aggregate the data, helped by the zone maps and by the structures that queries build. A complete trace of the route of every query will be added here.

Only these shapes take the shortcut. A filter such as `col <> 1`, or one more aggregate such as `SUM(IsRefresh)`, makes the same query scan the table, and the same query then takes from a few tens of milliseconds to about a hundred on 10 million rows, instead of a few milliseconds. The hot times of these 14 queries in the results are therefore not scan times.

`EXPLAIN` does not show this: for `SELECT COUNT(*) FROM hits` it reports a scan. That is a defect in `EXPLAIN`, not a hidden step.

## Known problems in this version

- On the 192-vCPU machines (c6a.metal, c7a.metal-48xl) the CI run of 23.0.2 failed 21 of the 43 queries with `Index was outside the bounds of the array`. We found the cause: a table of 64 per-thread slots that more than 64 threads overflow. It is a bug in the engine, not in this entry.
- The concurrent test failed in the CI runs on c6a.4xlarge and c6a.2xlarge. The watchdog restarts the server when one `./check` fails. In our own test the server's readiness check could be delayed by several seconds while ten clients ran heavy statements, and we changed the server for that. It has not been checked in CI.
- There is no linux/arm64 image in 23.0.2, so the c8g runs stop at `docker pull`.
- The load time on the CI machines was longer than on ours (615 s against 374 s on c6a.4xlarge). We do not know why.

## Licence

HoloDb is closed-source software under a commercial licence. `LICENSE-BENCHMARKING.md` in this directory allows the ClickBench maintainers, and anyone reproducing this entry, to run it, examine its behaviour and publish what they find, including criticism.

The entry is in the `joke` category, because the licence of HoloDb forbade examining how the engine gets its results. `LICENSE-BENCHMARKING.md` changes that.
