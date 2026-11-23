HoloDb run as a server, pinned to HoloDb 23.3.0 (`HOLODB_VERSION` in `bench.env`: the image tag and the loader package). The published image (`ghcr.io/evaluatedapplications/holodb`) serves the store from a bind-mounted directory; queries go over TLS from a small .NET client. More about HoloDb: https://evaluatedapplications.github.io/holodb/

## Configuration of this entry

This entry runs with HoloDb's stored aggregates off. `bench.env` sets `HOLODB_STORED_AGGREGATES=off` unless the environment already sets it (`HOLODB_STORED_AGGREGATES=on` or `off`). The setting is read by the loader, so it applies when `load` runs:

- **off (this entry):** the loader calls `Database.SetStoredAggregates("hits", false)`. The load builds no value counts (`valuecounts.off` marker, no `valuecounts.idx`), and the whole-table totals route is switched off (`totalsroute.off` marker). Every statement reads rows. The totals are still kept current on every write and used inside the engine (checks, seal, zone maps); they answer no statement.
- **on:** the HoloDb product default. The load builds the value counts, and 14 of the 43 statements are answered from stored data (below).

Zone maps, predicate records, function maps and order ranks are on in both settings. Predicate records and function maps are built by queries and deleted by `./stop` (see below).

The markers are saved in the store directory and are read when the store opens. To change the setting, run `./load` again with the new value.

## Scripts

- `install` pulls the image and builds the client and loader.
- `load` writes the store from `hits.parquet`; `start` runs the container; `stop` stops it.
- `query` reads one statement on stdin, prints rows, and prints the elapsed seconds on the last stderr line. The timer covers `ExecuteAsync` (send, execute, receive, decode). Connection setup, the TLS handshake and printing the rows are outside it.
- `STRLEN(` is rewritten to `OCTET_LENGTH(` (same byte count; the standard name).
- The server is started with `--dialect extended` (the official queries use `LIMIT`, `DATE_TRUNC`, `REGEXP_REPLACE`), `--paged`, `--statement-seconds 600`, and a token file. The container runs with the .NET server GC (`DOTNET_gcServer=1`), and the image sets `DOTNET_TC_CallCountingDelayMs=0`. There are no other settings.
- The loader uses DuckDB (the `DuckDB.NET` package) only to read `hits.parquet` and hand the rows to HoloDb's bulk loader. No query runs on DuckDB, and the image contains no other database.

## What the engine keeps

HoloDb keeps the columns as the authoritative data, in its own typed storage, and keeps statistics derived from them. Nothing is set up or configured. No result set is stored, and a structure answers a statement only when it is exact for that statement; otherwise the statement reads rows. Some structures are keyed by a predicate, or by a function and its constants (the predicate records and function maps below). They are saved in files and make the second and third runs of the queries that use them faster. The name HoloDb comes from its per-row holographic encodings (vector-symbolic bind and bundle), which serve the `NEAREST` operator. None of the 43 queries uses them.

These structures are kept for analytic tables (tables without a primary key and without NULL columns, which `hits` is).

**Built by `load`:**
- Per-column totals: row count, sum (exact, in 128-bit integers), minimum and maximum. Kept current on every write. In this entry they answer no statement (totals route off).
- Value counts (`valuecounts.idx`): the number of rows for each distinct value of a column. In this entry none are built (off). With the product default they are built at load, are not kept current (after a write they are not used until the table is closed cleanly, which rewrites the file), and are part of the data size. At 10 million rows, 101 of the 105 columns have them.
- Zone maps: the minimum and maximum of each block of 16,384 rows of an integer or date column. In this entry they are on. A scan skips an 8,192-row scan unit only when it lies inside a full block whose zone excludes the query's literal.

**Built by queries.** The first query that needs one builds it. Later runs load it from its file, and runs 2 and 3 of a query are faster for it. There is no setting for these.
- Predicate records, keyed by the dictionary, the predicate and its constants. One match bit per distinct text value, for `LIKE`, `ILIKE` and `OCTET_LENGTH(col) <op> n`. Used by Q21 to Q24.
- Function maps, keyed by the function name and its constant arguments. The result of the function for each distinct text value (`REGEXP_REPLACE`, `SUBSTRING`, `REPLACE`, `LOWER`, `UPPER`, `TRIM`). Used by Q29.
- Order ranks: the sort position of each distinct value, for a text column with at least 2^20 distinct values. None of the 43 queries used one at 10 million rows. At 100 million rows we saw an `orderrank.idx` of about 103 MB, so they are built there; we have not established which queries use them.

These describe a column's values. The rows are still read and aggregated. `./stop` deletes the files that queries built and restores the load-time versions of the others, so each query's first run starts with only what `load` built. `learned.idx` and `derived.idx` are also written next to the table; they are small headers with no content for these queries (we saw 1,560 and 1,638 bytes). Because `stop` deletes the query-built files after each query, the data size of this entry counts at most the files of the last query, not all of them. During one run at 100 million rows we saw function maps of about 403 MB, order ranks of about 103 MB and predicate records of about 2.3 MB next to the table (so order ranks are built at that size; we have not established which queries use them). The deletion is in `./stop`; remove it to see the full set.

**Statements answered from stored data (with `HOLODB_STORED_AGGREGATES=on` only).** Counting from 1 in `queries.sql`, 14 statements read no row of the table:
- Q1, Q3, Q4, Q7 and Q30 from the column totals. A `SUM(col + k)` is computed as `SUM(col) + k * COUNT(*)`, which is how Q30 is answered.
- Q2, Q5, Q6, Q8, Q13, Q16, Q34, Q35 and Q36 from the value counts. The recognised shapes are `COUNT(*)` with one `col <> 0` or `col <> ''` filter, `COUNT(DISTINCT col)`, and `GROUP BY col` with `COUNT(*)`. A constant key (`GROUP BY 1, URL`) is dropped, and a key `col - k` next to `col` is dropped too (Q36 groups by ClientIP alone).

Only these shapes take the shortcut, and they are the forms the ClickBench queries use (the comparison with `0` or `''`, `SUM(col + k)`, a constant or `col - k` group key). The same question written another way is not recognised and scans, although the counts are stored. A `WHERE` clause such as `col <> 1` makes a statement scan. For the value-count statements, one more aggregate such as `SUM(IsRefresh)` also makes them scan. For the totals, an extra `SUM` of a plain column is still answered from the totals.

A maintainer described the product's load as pre-aggregating every column. This entry runs with those stored aggregates off. The product default is on. The category is the maintainers' decision.

## Routes at 10 million rows (this entry's configuration)

Routes and rows read come from the engine's counters on a 10 million row store loaded with both options off (`cbload ... vc=off totals=off`, HoloDb 23.3.0 Bench build). "Morsels" are 8,192-row scan units, rounded up; the table has 1,221. The rows are from one run of each statement in our check.

| Query | How it is answered | Rows read at 10M (morsels/rows) |
|---|---|---|
| 1 | scan, hash aggregation | 1221m/10000000r |
| 2 | scan, hash aggregation | 1221m/10000000r |
| 3 | scan, hash aggregation | 1221m/10000000r |
| 4 | scan, hash aggregation | 1221m/10000000r |
| 5 | scan, hash aggregation | 1221m/10000000r |
| 6 | scan, hash aggregation | 1221m/10000000r |
| 7 | scan, hash aggregation | 1221m/10000000r |
| 8 | scan, dense array | 1221m/10000000r |
| 9 | scan, dense array | 1221m/10000000r |
| 10 | scan, dense array | 1221m/10000000r |
| 11 | scan, dense array | 1221m/10000000r |
| 12 | scan, hash aggregation | 1221m/10000000r |
| 13 | scan, hash aggregation | 1221m/10000000r |
| 14 | scan, hash aggregation | 1221m/10000000r |
| 15 | scan, hash aggregation | 1221m/10000000r |
| 16 | scan, hash aggregation | 1221m/10000000r |
| 17 | scan, hash aggregation | 1221m/10000000r |
| 18 | scan, first-keys group (GROUP BY .. LIMIT with no ORDER BY) | 1221m/10000000r |
| 19 | scan, hash aggregation | 1221m/10000000r |
| 20 | scan, plain; zone-pruned (1060 of 1221 morsels skipped) | 161m/1316480r |
| 21 | scan, hash aggregation; predicate record | 1221m/10000000r |
| 22 | scan, hash aggregation; predicate record | 1221m/10000000r |
| 23 | scan, hash aggregation; predicate record | 1221m/10000000r |
| 24 | scan, top-K heap; predicate record; top-K morsel pruning | 1169m/9574016r |
| 25 | scan, top-K heap; top-K morsel pruning | 990m/8107648r |
| 26 | scan, top-K heap | 1221m/10000000r |
| 27 | scan, top-K heap; top-K morsel pruning | 990m/8107648r |
| 28 | scan, dense array | 1221m/10000000r |
| 29 | scan, hash aggregation; function map | 1221m/10000000r |
| 30 | scan, hash aggregation | 1221m/10000000r |
| 31 | scan, hash aggregation | 1221m/10000000r |
| 32 | scan, hash aggregation | 1221m/10000000r |
| 33 | scan, hash aggregation | 1221m/10000000r |
| 34 | scan, hash aggregation | 1221m/10000000r |
| 35 | scan, hash aggregation | 1221m/10000000r |
| 36 | scan, hash aggregation | 1221m/10000000r |
| 37 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 38 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 39 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 40 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 41 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 42 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |
| 43 | scan, hash aggregation; zone-pruned (1142 of 1221 morsels skipped) | 79m/644736r |

All 43 statements read rows. "Hash aggregation" is the name `EXPLAIN` gives to the partitioned or per-worker aggregation, which it chooses at run time from a sample of four blocks. The predicate-record and function-map annotations come from the engine's counters (the records served Q21 to Q24 on every run; the function map served Q29 on every run). `./trace` does not print these two annotations; its output lists the zone tests and the declined structures only.

With `HOLODB_STORED_AGGREGATES=on`, Q1 to Q8, Q13, Q16, Q30, Q34, Q35 and Q36 read no row and the other 29 routes are the ones in this table.

## Measured at 100 million rows (this entry's configuration)

One run on one c6a.4xlarge, with the published 23.3.0 image and packages (`./install` to `./benchmark.sh`), the stored aggregates off, on an EBS volume provisioned at 6,000 IOPS and 500 MB/s:

- Load 319.5 s. Startup 2.91 s. Data size 30,185,789,714 bytes, which is 1,387,629,524 bytes less than the 31,573,419,238 bytes we measured with the stored aggregates on (the size of `valuecounts.idx`).
- Concurrent test: QPS 1.775, error ratio 0.000, and no kernel out-of-memory event on the instance.
- The sum of the cold times of the 43 statements is 110.9 s and the sum of the hot times (the faster of runs 2 and 3) is 19.85 s. For comparison, an earlier run with the stored aggregates on (the 23.1.1 code built from source, another instance session) had 98.9 s and 12.78 s.

After the run we reloaded the same instance with `HOLODB_STORED_AGGREGATES=on` and compared the output of all 43 statements between the two stores. 39 are identical byte for byte. Q39 returns the same rows in a different order among equal counts. Q32, Q33 and Q42 return different rows among tied counts at the `LIMIT`/`OFFSET` boundary; their count columns are identical. We have not compared any answer with another database's through the server.

## What EXPLAIN reports

`EXPLAIN` (extended dialect) reports the route the engine takes for a statement on these tables: the route name, the structure that answered it or the reason each other structure declined, and the rows read. For `SELECT COUNT(*) FROM hits` with the totals route off, it says the totals route is switched off for the table and the rows are read. With the product default it says "typed executor: per-column totals" and "rows read 0 of 10,000,000 slots". For a scan it gives an estimate before the run ("about 10,000,000 of 10,000,000 slots"), because the exact count is known only after the statement runs. For a zone-pruned scan the estimate can differ from the rows the run reads: for Q37 it said about 1,250,000, and the run read 644,736. `./trace` prints this output for every statement.

## Known problems

These are measurements from our earlier runs (23.1.1 built from source, and the published 23.2.0 image) on the 100 million row table, with the stored aggregates on unless stated.

- **192-vCPU machines (c6a.metal, c7a.metal-48xl).** In CI, 23.0.2 failed 21 of the 43 queries with `Index was outside the bounds of the array`. The cause was a table of 64 per-thread slots, which more than 64 threads overflow. 23.1.0 sizes the table from the number of chunks. We have not run this version on a real 192-vCPU host. Our many-core check simulates up to 256 workers on 16 cores.
- **Concurrent test on c6a.4xlarge and c6a.2xlarge.** The CI runs failed here. The cause was memory: the kernel out-of-memory killer stopped the server when ten clients ran heavy statements on the 100 million row table. In one such run the server's anonymous memory was about 29.7 GiB (`dmesg`). The memory governor admitted statements on estimates and did not bound their memory once they ran. 23.1.1 changes this. On c6a.4xlarge at 100 million rows, the concurrent error ratio in our harness was 0.000 with the 23.1.1 code built from source, and two 10 minute runs of ten clients completed 1,709 and 1,900 statements with no failed statement. With the published 23.2.0 image we measured 0.000 on c6a.4xlarge with the value counts off (totals route on) and on c8g.4xlarge with the stored aggregates on. 23.1.0 still failed in this way (error ratio 0.246 in our run, with the kernel kill). With the published 23.3.0 image in this entry's configuration (stored aggregates off) the error ratio was 0.000 on c6a.4xlarge. We have not run c6a.2xlarge.
- **arm64.** The image is published for linux/amd64 and linux/arm64 (a multi-architecture image from 23.1.0). We ran the whole entry (23.2.0, the published image and packages, `./install` to `./benchmark.sh`, stored aggregates on) on one c8g.4xlarge: the load took 358 s, the data size was identical to the x86 run (31,573,419,238 bytes), the concurrent error ratio was 0.000, and `./trace` printed the routes. We have not run the larger c8g machines or 23.3.0 on arm64.
- **Results files.** The files under `results/` were produced by the CI runs of version 23.0.2 (for example the 192-vCPU machines with failed queries and c6a.4xlarge with the concurrent failure). They do not describe 23.3.0.
- **Load time.** A 100 million row load took 362 s in our 23.1.1 run and 615 s in CI. Across our runs of this flow the load took between 356 s and 628 s. We have not established the cause. For what it is worth: our one run on a default gp3 volume (3,000 IOPS, 125 MB/s) took 568 s, and our runs on a volume provisioned at 6,000 IOPS and 500 MB/s took 358 s to 417 s. We changed nothing else on purpose, but the code differed slightly between those runs, so this is an observation, not a measurement of the disk's effect.

## Reproducing the routes

These commands need the server running (`./start`) on a loaded store. Each statement goes through `./query`, as in the timed runs.

- `./trace` prints the `EXPLAIN` output of all 43 statements in `queries.sql`, in order. `./trace 5` prints query 5 only. It works with either setting.
- `variants.sql` has 14 statements, one for each shortcut query in query order (line 1 is query 1, line 8 is query 8, and so on). Each keeps the query's select list and grouping, and adds or replaces the `WHERE` comparison with one the shortcut does not recognise (`<> 1` on an integer column, `<> 'a'` or `<> 'x'` on a text column). The variants only matter with `HOLODB_STORED_AGGREGATES=on`: there the plain statements read no row and the variants scan all rows. With `off`, the plain statements already scan, and the variants scan the same way. At 10 million rows each variant reads all 10,000,000 rows under both settings. To run variant 8: `sed -n '8p' variants.sql | ./query`. To see its route: `sed -n '8p' variants.sql | sed 's/^/EXPLAIN /; s/;$//' | ./query`.
- The product default, which answers 14 statements from stored data: `HOLODB_STORED_AGGREGATES=on ./benchmark.sh`. This entry's configuration: `./benchmark.sh` (the default in `bench.env` is off).
- To change the setting on a store that already exists, run `HOLODB_STORED_AGGREGATES=on ./load` (or `off`). `./load` removes the old store first.

## Licence

HoloDb is closed-source software under a commercial licence. `LICENSE-BENCHMARKING.md` in this directory allows the ClickBench maintainers, and anyone reproducing this entry, to run it, examine its behaviour and publish what they find, including criticism.

A maintainer moved this entry to the `joke` category because the earlier README was false, because the load pre-aggregates every column, and because the licence of HoloDb forbids decompiling, so nobody else can check how the engine gets its results. `LICENSE-BENCHMARKING.md` now allows running the software, examining its behaviour from the outside (plans, timings, the files it writes, its answers to changed queries or data) and publishing what is found, including criticism. It does not allow decompiling. The category is the maintainers' decision.
