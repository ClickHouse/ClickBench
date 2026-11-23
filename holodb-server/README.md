HoloDb run as a server, pinned to HoloDb 23.3.0 (`HOLODB_VERSION` in `bench.env`: the image tag and the loader package). The published image (`ghcr.io/evaluatedapplications/holodb`) serves the store from a bind-mounted directory; queries go over TLS from a small .NET client. More about HoloDb: https://evaluatedapplications.github.io/holodb/

## Configuration of this entry

This entry runs with HoloDb's stored aggregates off. `bench.env` sets `HOLODB_STORED_AGGREGATES=off` unless the environment already sets it (`HOLODB_STORED_AGGREGATES=on` or `off`). The setting is read by the loader, so it applies when `load` runs:

- **off (this entry):** the loader calls `Database.SetStoredAggregates("hits", false)`. The load builds no value counts (`valuecounts.off` marker, no `valuecounts.idx`), and the whole-table totals route is switched off (`totalsroute.off` marker). Every statement is a scan (Q1 is `COUNT(*)`, which needs no column). The totals are still kept current on every write and used inside the engine (checks, seal, zone maps); they answer no statement. `EXPLAIN` names the switch `SetTotalsRoute`; `SetStoredAggregates` sets both it and the value counts.
- **on:** the HoloDb product default. The load builds the value counts, and 14 of the 43 statements are answered from stored data (below).

Zone maps, predicate records, function maps and order ranks are on in both settings. Predicate records and function maps are built by queries and deleted by `./stop` (see below).

The markers are saved in the store directory and are read when the store opens. To change the setting, run `./load` again with the new value.

## Scripts

- `install` pulls the image and builds the client and loader.
- `load` writes the store from `hits.parquet`; `start` runs the container; `stop` stops it.
- `query` reads one statement on stdin, prints rows, and prints the elapsed seconds on the last stderr line. The timer covers `ExecuteAsync` (send, execute, receive, decode). Connection setup, the TLS handshake and printing the rows are outside it.
- The client rewrites `STRLEN(` to `OCTET_LENGTH(` before sending (same byte count; the standard name), so `queries.sql` is the official file unchanged.
- The server is started with `--wal /data/holo` (the write-ahead log beside the store), `--paged`, `--dialect extended` (the official queries use `LIMIT`, `DATE_TRUNC`, `REGEXP_REPLACE`), `--statement-seconds 600`, and a token file; the container runs as the benchmark user (`--user`) with the .NET server GC (`DOTNET_gcServer=1`), and the image sets `DOTNET_TC_CallCountingDelayMs=0`. The container also sets `HOME=/tmp`, and the loader limits DuckDB's memory and threads while it reads the parquet file. Those and the stored-aggregates switch are all the settings we pass; `template.json` says `"tuned": "yes"` because the switch and the GC mode are choices made for this run.
- The loader uses DuckDB (the `DuckDB.NET` package) only to read `hits.parquet` and hand the rows to HoloDb's bulk loader. No query runs on DuckDB, and the image contains no other database.

## What the engine keeps

HoloDb keeps the columns as the authoritative data, in its own typed storage, and keeps statistics derived from them. No index is created by statement and no table option is set by hand. No result set is stored, and a structure answers a statement only when it is exact for that statement; otherwise the statement reads rows. Some structures are keyed by a predicate, or by a function and its constants (the predicate records and function maps below). They are saved in files and make the second and third runs of the queries that use them faster. The name HoloDb comes from its per-row holographic encodings (vector-symbolic bind and bundle), which serve the `NEAREST` operator. None of the 43 queries uses them.

These structures are kept for analytic tables (tables without a primary key and without NULL columns, which `hits` is).

**Built by `load`:**
- Per-column totals: row count, sum (exact, in 128-bit integers), minimum and maximum. Kept current on every write. In this entry they answer no statement (totals route off).
- Value counts (`valuecounts.idx`): the number of rows for each distinct value of a column. In this entry none are built (off). With the product default they are built at load, are not kept current (after a write they are not used until the table is closed cleanly, which rewrites the file), and are part of the data size. At 10 million rows, 101 of the 105 columns have them.
- Zone maps: the minimum and maximum of each block of 16,384 rows of an integer or date column. In this entry they are on. A scan skips an 8,192-row scan unit only when it lies inside a full block whose zone excludes the query's literal.

**Built by queries.** The first query that needs one builds it. Later runs load it from its file, and runs 2 and 3 of a query are faster for it. There is no setting for these.
- Predicate records, keyed by the dictionary, the predicate and its constants. One match bit per distinct text value, for `LIKE`, `ILIKE` and `OCTET_LENGTH(col) <op> n`. Used by Q21 to Q24.
- Function maps, keyed by the function name and its constant arguments. The result of the function for each distinct text value (`REGEXP_REPLACE`, `SUBSTRING`, `REPLACE`, `LOWER`, `UPPER`, `TRIM`). Used by Q29.
- Order ranks: the sort position of each distinct value, for a text column with at least 2^20 distinct values. None of the 43 queries used one at 10 million rows. At 100 million rows we saw an `orderrank.idx` of about 103 MB, so they are built there; we have not established which queries use them.

These describe a column's values. The rows are still read and aggregated. `./stop` deletes the files that queries built and restores the load-time versions of the others, so each query's first run starts with only what `load` built. `learned.idx` and `derived.idx` are also written next to the table; they are small headers with no content for these queries (we saw 1,560 and 1,638 bytes). Because `stop` deletes the query-built files after each query, the data size of this entry counts at most the files of the last query, not all of them. During one run at 100 million rows we saw function maps of about 403 MB, order ranks of about 103 MB and predicate records of about 2.3 MB next to the table. The deletion is in `./stop` and covers `*.idx` and `summary.*` files; it ignores errors, and always exits 0, so a failed restore would not be reported. Remove it to see the full set.

**Statements answered from stored data (with `HOLODB_STORED_AGGREGATES=on` only).** Counting from 1 in `queries.sql`, 14 statements read no row of the table:
- Q1, Q3, Q4, Q7 and Q30 from the column totals. A `SUM(col + k)` is computed as `SUM(col) + k * COUNT(*)`, which is how Q30 is answered.
- Q2, Q5, Q6, Q8, Q13, Q16, Q34, Q35 and Q36 from the value counts. The recognised shapes are `COUNT(*)` with one `col <> 0` or `col <> ''` filter, `COUNT(DISTINCT col)`, and `GROUP BY col` with `COUNT(*)`. A constant key (`GROUP BY 1, URL`) is dropped, and a key `col - k` next to `col` is dropped too (Q36 groups by ClientIP alone).

Only these shapes take the shortcut, and they are the forms the ClickBench queries use (the comparison with `0` or `''`, `SUM(col + k)`, a constant or `col - k` group key). The same question written another way is not recognised and scans, although the counts are stored. A `WHERE` clause such as `col <> 1` makes a statement scan. For the value-count statements, one more aggregate such as `SUM(IsRefresh)` also makes them scan. For the totals, an extra `SUM` of a plain column is still answered from the totals.

## Routes at 100 million rows (this entry's configuration)

This is the output of `./trace` (the `EXPLAIN` of each statement) on the 100 million row store of the 23.3.0 run below, with the stored aggregates off. Anyone can reproduce it with `./trace` (see the end of this file). "Rows" is the engine's estimate before the run ("about N of 99,997,497 slots"); the exact count is known only after the statement runs, and `EXPLAIN` does not print it afterwards. Where a zone test excludes sampled blocks, a scan skips the morsels (8,192-row scan units) inside the excluded blocks, so the rows read are fewer than the estimate for the rest. For Q37 to Q43 all eight sampled blocks are excluded, so the estimate is 0; that is an estimate from a sample, not a claim that no row is read (on a 10 million row store, the same statements read 644,736 rows).

| Query | How it is answered | Rows (estimate) | Zone / pruning |
|---|---|---|---|
| 1 | scan, hash aggregation | 99,997,497 |  |
| 2 | scan, hash aggregation | 49,998,748 | zone test AdvEngineID <> 0 (4 of 8 sampled blocks excluded) |
| 3 | scan, hash aggregation | 99,997,497 |  |
| 4 | scan, hash aggregation | 99,997,497 |  |
| 5 | scan, hash aggregation | 99,997,497 |  |
| 6 | scan, hash aggregation | 99,997,497 |  |
| 7 | scan, hash aggregation | 99,997,497 |  |
| 8 | scan, dense array | 49,998,748 | zone test AdvEngineID <> 0 (4 of 8 sampled blocks excluded) |
| 9 | scan, dense array | 99,997,497 |  |
| 10 | scan, dense array | 99,997,497 |  |
| 11 | scan, dense array | 99,997,497 |  |
| 12 | scan, hash aggregation | 99,997,497 |  |
| 13 | scan, hash aggregation | 99,997,497 |  |
| 14 | scan, hash aggregation | 99,997,497 |  |
| 15 | scan, hash aggregation | 99,997,497 |  |
| 16 | scan, hash aggregation | 99,997,497 |  |
| 17 | scan, hash aggregation | 99,997,497 |  |
| 18 | scan, first-keys group | 99,997,497 |  |
| 19 | scan, hash aggregation | 99,997,497 |  |
| 20 | scan, plain | 49,998,748 | zone test UserID = 435090932899640449 (4 of 8 sampled blocks excluded) |
| 21 | scan, hash aggregation | 99,997,497 |  |
| 22 | scan, hash aggregation | 99,997,497 |  |
| 23 | scan, hash aggregation | 99,997,497 |  |
| 24 | scan, top-K heap | 99,997,497 | top-K morsel pruning |
| 25 | scan, top-K heap | 99,997,497 | top-K morsel pruning |
| 26 | scan, top-K heap | 99,997,497 |  |
| 27 | scan, top-K heap | 99,997,497 | top-K morsel pruning |
| 28 | scan, dense array | 99,997,497 |  |
| 29 | scan, hash aggregation | 99,997,497 |  |
| 30 | scan, hash aggregation | 99,997,497 |  |
| 31 | scan, hash aggregation | 99,997,497 |  |
| 32 | scan, hash aggregation | 99,997,497 |  |
| 33 | scan, hash aggregation | 99,997,497 |  |
| 34 | scan, hash aggregation | 99,997,497 |  |
| 35 | scan, hash aggregation | 99,997,497 |  |
| 36 | scan, hash aggregation | 99,997,497 |  |
| 37 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded) |
| 38 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded) |
| 39 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded); zone test IsLink <> 0 (5 of 8 sampled blocks excluded) |
| 40 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded) |
| 41 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded) |
| 42 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded) |
| 43 | scan, hash aggregation | 0 | zone test CounterID = 62 (8 of 8 sampled blocks excluded); zone test EventDate <= 15901 (4 of 8 sampled blocks excluded) |

All 43 statements are scans: each `EXPLAIN` says "no stored aggregate answers this statement: it reads rows". Q1 is `COUNT(*)`, which needs no column, so its scan touches none. We have not established how the engine evaluates the 90 sums of Q30 (whether it shares one pass over the column). "Hash aggregation" is the name `EXPLAIN` gives to the partitioned or per-worker aggregation, which it chooses at run time from a sample of four blocks.

`EXPLAIN` does not print the predicate records, function maps or order ranks. From the engine's own counters on a 10 million row store (not reproducible with `./trace`) the predicate records served Q21 to Q24 and the function map served Q29 on every run; at 100 million rows we have not recorded which statements use which.

With `HOLODB_STORED_AGGREGATES=on`, `./trace` shows Q1 to Q8, Q13, Q16, Q30, Q34, Q35 and Q36 answered from stored data with no row read (14 statements); the other 29 routes are the ones above (checked on the earlier on-run traces).

## Measured at 100 million rows (this entry's configuration)

One run on one c6a.4xlarge, with the published 23.3.0 image and packages (`./install` to `./benchmark.sh`), the stored aggregates off, on an EBS volume provisioned at 6,000 IOPS and 500 MB/s:

- Load 319.5 s. Startup 2.91 s. Data size 30,185,789,714 bytes, which is 1,387,629,524 bytes less than the 31,573,419,238 bytes we measured with the stored aggregates on (the size of `valuecounts.idx`).
- Concurrent test: QPS 1.775, error ratio 0.000, and no kernel out-of-memory event on the instance.
- The sum of the cold times of the 43 statements is 110.9 s and the sum of the hot times (the faster of runs 2 and 3) is 19.85 s. For comparison, an earlier run with the stored aggregates on (the 23.1.1 code built from source, another instance session) had 98.9 s and 12.78 s.

After the run we reloaded the same instance with `HOLODB_STORED_AGGREGATES=on` and compared the output of all 43 statements between the two stores. 39 are identical byte for byte. Q39 returns the same rows in a different order among equal counts. Q32, Q33 and Q42 return different rows among tied counts at the `LIMIT`/`OFFSET` boundary; their count columns are identical. We have not compared any answer with another database's through the server.

## What EXPLAIN reports

`EXPLAIN` (extended dialect) reports the route the engine takes for a statement on these tables: the route name, the stored structure that answered it or the reason each stored aggregate declined, zone tests, and an estimate of the rows read. It does not print the predicate records, function maps or order ranks, so it does not show every structure a statement used. For `SELECT COUNT(*) FROM hits` with the totals route off, it says the totals route is switched off for the table and the rows are read. With the product default it says "typed executor: per-column totals" and "rows read 0 of N slots". For a scan it gives an estimate before the run ("about N of N slots"), because the exact count is known only after the statement runs. For a zone-pruned scan the estimate can differ from the rows the run reads: on a 10 million row store, for Q37 it said about 1,250,000, and the run read 644,736. `./trace` prints this output for every statement.

## Known problems

These are measurements on the 100 million row table: our own runs (23.1.1 built from source; the published 23.2.0 and 23.3.0 images) and the CI runs of 23.0.2 whose files were removed from `results/` (below). The stored aggregates were on unless stated.

- **192-vCPU machines (c6a.metal, c7a.metal-48xl).** In CI, 23.0.2 returned no result for at least one of the three runs of 21 of the 43 queries (15 of them in all three runs) on both machines, with `Index was outside the bounds of the array`. The cause was a table of 64 per-thread slots, which more than 64 threads overflow. 23.1.0 sizes the table from the number of chunks. We have not run 23.1.0 or later on a real 192-vCPU host. Our many-core check simulates up to 256 workers on 16 cores.
- **Concurrent test.** In the CI runs of 23.0.2 the concurrent error ratio was 0.837 on c6a.4xlarge, 0.174 on c6a.2xlarge, 0.216 on c6a.xlarge, 0.154 on c6a.metal and 0.094 on c7a.metal-48xl. We investigated c6a.4xlarge. The cause was memory: the kernel out-of-memory killer stopped the server when ten clients ran heavy statements on the 100 million row table. In one such run the server's anonymous memory was about 29.7 GiB (`dmesg`). The memory governor admitted statements on estimates and did not bound their memory once they ran. 23.1.1 changes this. On c6a.4xlarge at 100 million rows, the concurrent error ratio in our harness was 0.000 with the 23.1.1 code built from source, and two 10 minute runs of ten clients completed 1,709 and 1,900 statements with no failed statement. With the published 23.2.0 image we measured 0.000 on c6a.4xlarge with the value counts off (totals route on) and on c8g.4xlarge with the stored aggregates on. 23.1.0 still failed in this way (error ratio 0.246 in our run, with the kernel kill). With the published 23.3.0 image in this entry's configuration (stored aggregates off) the error ratio was 0.000 on c6a.4xlarge. We have not run c6a.2xlarge or c6a.xlarge, so we do not know that those fail no longer.
- **arm64.** The image is published for linux/amd64 and linux/arm64 (a multi-architecture image from 23.1.0). We ran the whole entry (23.2.0, the published image and packages, `./install` to `./benchmark.sh`, stored aggregates on) on one c8g.4xlarge: the load took 358 s, the data size was identical to the x86 run (31,573,419,238 bytes), the concurrent error ratio was 0.000, and `./trace` printed the routes. We have not run the larger c8g machines or 23.3.0 on arm64.
- **Results files.** `results/20261122/` held five CI runs of version 23.0.2 with the stored aggregates on (c6a.xlarge, c6a.2xlarge, c6a.4xlarge, c6a.metal, c7a.metal-48xl). They do not describe this entry (23.3.0, stored aggregates off), so they were removed from `results/` (not hidden: they remain in the history of this pull request, and the failures are listed here). Their loads took 10,608 s (c6a.xlarge), 1,906 s (c6a.2xlarge), 615 s (c6a.4xlarge), 192 s (c6a.metal) and 218 s (c7a.metal-48xl). Results for the current version are to be produced by the maintainers' CI.
- **Load time.** On c6a.4xlarge, a 100 million row load took 362 s in our 23.1.1 run and 615 s in CI (23.0.2). Across our own runs of this flow on that instance type the load took between 319 s and 628 s; the CI runs on smaller machines took far longer (above). We have not established the cause. For what it is worth: our one run on a default gp3 volume (3,000 IOPS, 125 MB/s) took 568 s, and our runs on a volume provisioned at 6,000 IOPS and 500 MB/s took 319 s to 417 s. We changed nothing else on purpose, but the code differed slightly between those runs, so this is an observation, not a measurement of the disk's effect.

## Reproducing the routes

These commands need the server running (`./start`) on a loaded store. Each statement goes through `./query`, as in the timed runs.

- `./trace` prints the `EXPLAIN` output of all 43 statements in `queries.sql`, in order. `./trace 5` prints query 5 only. It works with either setting.
- `variants.sql` has 14 statements, one for each shortcut query in query order (lines 1 to 8 are queries 1 to 8; lines 9 to 14 are queries 13, 16, 30, 34, 35 and 36). Each keeps the query's select list and grouping, and adds or replaces the `WHERE` comparison with one the shortcut does not recognise (`<> 1` on an integer column, `<> 'a'` or `<> 'x'` on a text column, a date literal for variant 7). The variants only matter with `HOLODB_STORED_AGGREGATES=on`: there the plain statements read no row and the variants scan all rows. With `off`, the plain statements already scan, and the variants scan the same way. At 10 million rows each variant reads all 10,000,000 rows under both settings. To run variant 8 (query 8): `sed -n '8p' variants.sql | ./query`. To see its route: `sed -n '8p' variants.sql | sed 's/^/EXPLAIN /; s/;$//' | ./query`.
- The product default, which answers 14 statements from stored data: `HOLODB_STORED_AGGREGATES=on ./benchmark.sh`. This entry's configuration: `./benchmark.sh` (the default in `bench.env` is off).
- To change the setting on a store that already exists, run `HOLODB_STORED_AGGREGATES=on ./load` (or `off`). `./load` removes the old store first.

## Licence

HoloDb is closed-source software under a commercial licence. `LICENSE-BENCHMARKING.md` in this directory allows the ClickBench maintainers, and anyone reproducing this entry, to run it, examine its behaviour and publish what they find, including criticism.

A maintainer moved this entry to the `joke` category because the earlier README was false, because the load pre-aggregates every column, and because the licence of HoloDb forbids decompiling, so nobody else can check how the engine gets its results. `LICENSE-BENCHMARKING.md` now allows running the software, examining its behaviour from the outside (plans, timings, the files it writes, its answers to changed queries or data) and publishing what is found, including criticism. It does not allow decompiling. The category is the maintainers' decision.
