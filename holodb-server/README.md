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

The totals are kept current on every insert, update and delete. The value counts are not: after any write they cannot be used, and the queries that rely on them scan until the next clean close rebuilds them. If aluecounts.idx is deleted, the engine scans and returns the same results (checked on the first 10 million rows with the shortcuts switched off). An answer taken from these structures is exact or the engine declines to use them.

**Built by queries.** Per-column match bits for text predicates such as `LIKE` and `OCTET_LENGTH` comparisons, and per-column order ranks (the sort position of each distinct value) used by `ORDER BY ... LIMIT`, `MIN` and `MAX`. They describe a column's values and are saved next to the table. `stop` deletes them once the container is gone, so after a restart a query starts with only what `load` built; the second and third runs of a query use what its first run built. The store is created fresh by `load`.

**Which queries are answered without reading the rows.** A query that the totals or the value counts cover is answered from them. Counting from 1 in `queries.sql`:
- Queries 1, 3, 4, 7 and 30 are answered from the column totals. `SUM(col + k)` is computed as `SUM(col) + k * COUNT(*)`.
- Queries 2, 5, 6, 8, 13, 16, 34, 35 and 36 are answered from the value counts. These are `COUNT(*)` with a single `col <> 0` or `col <> ''` filter, `COUNT(DISTINCT col)`, and `GROUP BY col` with `COUNT(*)`. A constant key (`GROUP BY 1, URL`) and keys of the form `col - k` next to `col` are dropped first.

This list is the one the reviewers of this entry found, and we reproduced it with the engine's own per-statement counters on the first 10 million rows: these 14 queries read no row of the table (0 rows and at most a few pages), and with the shortcuts switched off their first 10 result rows are identical. The other 29 queries scan and aggregate the data, helped by the zone maps and by the structures that queries build. With the shortcuts switched off, the 14 queries take 5 to 136 ms on 10 million rows, and with them under 2 ms.

The route of every query, from the engine's counters (10 million rows is 1,221 blocks of 8,192 rows; 'rows read' is what the executor actually read; the first run in a process also builds the match bits that a LIKE test needs, see above):

| Query | How it is answered | Rows read at 10M (morsels/rows) |
|---|---|---|
| 1 | per-column totals | 0 (none) |
| 2 | value counts | 0 (none) |
| 3 | per-column totals | 0 (none) |
| 4 | per-column totals | 0 (none) |
| 5 | value counts | 0 (none) |
| 6 | value counts | 0 (none) |
| 7 | per-column totals | 0 (none) |
| 8 | value counts | 0 (none) |
| 9 | scan, dense per-worker array | 1221m/10000000r |
| 10 | scan, dense per-worker array | 1221m/10000000r |
| 11 | scan, dense per-worker array | 1221m/10000000r |
| 12 | scan, partitioned hash aggregation | 1221m/10000000r |
| 13 | value counts | 0 (none) |
| 14 | scan, partitioned hash aggregation | 1221m/10000000r |
| 15 | scan, partitioned hash aggregation | 1221m/10000000r |
| 16 | value counts | 0 (none) |
| 17 | scan, partitioned hash aggregation | 1221m/10000000r |
| 18 | scan, first-keys group (GROUP BY .. LIMIT with no ORDER BY) | 1221m/10000000r |
| 19 | scan, partitioned hash aggregation | 1221m/10000000r |
| 20 | scan, plain; zone-pruned (1060 of 1221 morsels skipped) | 161m/1316480r |
| 21 | scan, hash aggregation; predicate record | 1221m/10000000r |
| 22 | scan, partitioned hash aggregation; predicate record | 1221m/10000000r |
| 23 | scan, partitioned hash aggregation; predicate record | 1221m/10000000r |
| 24 | scan, top-K heap; predicate record; top-K block pruning by zone | 1169m/9574016r |
| 25 | scan, top-K heap; top-K block pruning by zone | 884m/7239296r |
| 26 | scan, top-K heap; top-K block pruning by zone | 1221m/10000000r |
| 27 | scan, top-K heap; top-K block pruning by zone | 976m/7992960r |
| 28 | scan, dense per-worker array | 1221m/10000000r |
| 29 | scan, partitioned hash aggregation | 1221m/10000000r |
| 30 | per-column totals | 0 (none) |
| 31 | scan, partitioned hash aggregation | 1221m/10000000r |
| 32 | scan, partitioned hash aggregation | 1221m/10000000r |
| 33 | scan, partitioned hash aggregation | 1221m/10000000r |
| 34 | value counts | 0 (none) |
| 35 | value counts | 0 (none) |
| 36 | value counts | 0 (none) |
| 37 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 38 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 39 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 40 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 41 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 42 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 43 | scan, partitioned hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |

At 10 million rows no order rank was used by any of the 43 queries (a rank needs a dictionary of at least 2^20 values). We have not measured whether they are used at 100 million rows. The value counts exist for 101 of the 105 columns at 10 million rows; WatchID, HID, RefererHash and URLHash have none.

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
