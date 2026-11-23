# TDengine

[TDengine TSDB](https://tdengine.com/) is an open-source (AGPL-3.0) time-series
DBMS written in C, aimed at industrial IoT: sensor, meter and telemetry data.
Its storage engine is columnar and its SQL dialect is close to standard SQL
with time-window extensions added (`INTERVAL`, `SESSION`, `STATE_WINDOW`,
`INTERP`). What makes it structurally different from the other engines in this
benchmark is its data model: TDengine expects one *table per device*, grouped
under a *supertable* that holds the shared schema plus per-device *tags*, and
almost everything about its performance follows from how a dataset is mapped
onto that shape.

This entry runs TDengine TSDB OSS 3.4.2.5 from the vendor's Linux tarball
(`install.sh`), queried over the REST endpoint that `taosadapter` exposes —
which is the connection method the
[docs recommend](https://docs.tdengine.com/operations-and-tooling/operations/planning/)
over the native `taosc` protocol.

## Caveats

Five, and the first three are why the queries and the loader here do not look
like their neighbours. Each is expanded on below.

1. **The dataset is modelled as a supertable with one subtable per
   `CounterID`.** A single TDengine table lives in exactly one vgroup and is
   scanned by exactly one thread, so a flat `hits` table would have used one
   CPU core on every machine in the benchmark.
2. **`COUNT(DISTINCT ...)` segfaults `taosd`** once the deduplicated set
   outgrows 16 MB, so all eight queries that use it deduplicate in a subquery
   instead.
3. **14 of the 43 queries produce no result at 100M rows** and are recorded as
   `null`: six are rejected by a hard ten-million-group ceiling, six run out of
   query memory, and two do not finish inside the timeout.
4. **Loading has to be chunked, and the chunking has to understand CSV** — the
   client buffers an entire `INSERT ... FILE` in memory, and a few thousand
   `URL` and `Referer` values contain literal newlines.
5. **`KEEP` has to be raised from its default** or the July 2013 dataset cannot
   be inserted at all.

## One subtable per counter

TDengine assigns *tables* to vgroups — the unit of sharding — and runs one
query task per vgroup. A basic (non-super) table therefore has all of its data
in one vnode, and a scan of it is single-threaded. That is easy to see: with
`hits` as a basic table holding a 1% slice, a `GROUP BY` over a regex on
`Referer` keeps exactly one `vnode-query` thread busy and leaves the other 95
cores idle.

So the table is a supertable, `CounterID` is its tag, and each counter's rows
live in a subtable named after that counter. That is the modelling TDengine
documents for any dataset with a natural series key, and `CounterID` is the
natural one here — it identifies the web counter that produced the hit, and it
is also the leading column of ClickBench's primary key in the ClickHouse
entry. The 100M rows spread over 6,506 subtables; `./load` sets the database's
`vgroups` to the core count, so all cores participate in a scan.

Two consequences worth stating plainly, both in TDengine's favour:

- `CounterID` is a tag, so it is stored once per subtable rather than once per
  row, and it does not appear in `./data-size` the way a 100M-row column
  would. Storing metadata once per series is the feature TDengine is built
  around, so this is the system working as designed rather than a trick.
- Filtering on a tag prunes to the matching subtables before any data is read,
  so Q37–Q43 (`CounterID = 62`) touch one subtable. This is the same kind of
  advantage ClickHouse gets from having `CounterID` first in its primary key.

`SELECT *` on a supertable returns the tag columns after the data columns, and
TDengine requires the primary timestamp in column 1, so Q24 returns the same
105 values per row in a different column order: `EventTime`, `WatchID`, then
the remaining columns in dataset order, then `CounterID`. Comparing the two
engines column-by-name shows all 1050 cells of Q24's ten rows identical.

### Why the load has to name `tbname`

`INSERT INTO <supertable> ... FILE` requires a `tbname` column in the field
list — it is what routes each row to a subtable, and TDengine creates the
subtable on first sight. `hits.csv` has no such column, and the field list may
not name a column twice, so `csv-columns.txt` maps `hits.csv`'s seventh field
(`CounterID`) onto `tbname`. Rows land in a subtable named `62`, `17`, … and
the `CounterID` *tag* of those auto-created subtables is left `NULL`, because
an auto-creating insert cannot also supply a tag value.

`./load` then reads the subtable names back out of
`information_schema.ins_tables` and sets each tag with `ALTER TABLE … SET
TAG`, batched about 1000 subtables per statement. The name *is* the value, so
nothing has to be inferred and no second pass over the data is needed.

(One trap if you edit this: `SELECT … >> file` writes CRLF line endings, and a
stray CR inside the backticks makes every `ALTER` fail with `Table does not
exist`.)

## `COUNT(DISTINCT ...)` segfaults the server

Reported upstream as
[taosdata/TDengine#35449](https://github.com/taosdata/TDengine/issues/35449).
This is a crash, not an error: `taosd` dies with `SIGSEGV`, the client reports
`Unable to establish connection`, and systemd restarts the service. It happens
whenever the deduplicated set outgrows `pqSortMemThreshold` (16 MB) and the
engine switches from hash deduplication to its spill-to-disk merge sort. It is
the spill path, not the column type: a two-column table is enough, and both
`BIGINT` (5,000,000 distinct values) and `VARCHAR(40)` (1,000,000) reproduce
it.

```sql
CREATE DATABASE crashtest;
CREATE TABLE crashtest.t (ts TIMESTAMP, v BIGINT);
-- 5,000,000 rows, all v distinct
SELECT COUNT(DISTINCT v) FROM crashtest.t;   -- taosd dies after ~70s
```

From the core dump, in the thread named `vnode-query`:

```
#0  colDataIsNull_t (isVarType=false, row=0, pColumnInfoData=0xfa6e7f0ff660)
        at include/common/tdatablock.h:110
#1  msortComparFn                     at source/libs/executor/src/tsort.c:943
#2  tMergeTreeAdjust                  at source/util/src/tlosertree.c:117
#3  tMergeTreeCreate                  at source/util/src/tlosertree.c:69
#4  tsortOpenForBufMergeSort          at source/libs/executor/src/tsort.c:2621
#5  tsortOpen                         at source/libs/executor/src/tsort.c:2964
#6  initSpillSortHandle   at source/libs/executor/src/distinctfilteroperator.c:175
#7  doDistinctFilter      at source/libs/executor/src/distinctfilteroperator.c:705
```

The sort comparator is handed a column-info pointer that does not describe the
column it is sorting. ClickBench has eight `COUNT(DISTINCT ...)` queries — Q5,
Q6, Q9, Q10, Q11, Q12, Q14 and Q23 — and every one of them deduplicates far
more than 16 MB (`UserID` alone is 17.6M distinct values, 141 MB), so all
eight would crash the server.

Rather than ship queries that kill the engine, they deduplicate in a subquery
— the shape the vendor's own docs suggest for cardinality (`select count(data)
from (select unique(col) as data from table)`). Ungrouped:

```sql
SELECT count(*) AS u FROM (SELECT DISTINCT UserID FROM hits)
```

and grouped, where the inner query deduplicates on `(key, UserID)` and the
outer one counts the survivors per key:

```sql
SELECT RegionID, count(*) AS u
FROM (SELECT DISTINCT RegionID, UserID FROM hits)
GROUP BY RegionID ORDER BY u DESC LIMIT 10
```

Q10 and Q23 mix `COUNT(DISTINCT UserID)` with other aggregates, so their inner
query aggregates per `(key, UserID)` and the outer one re-aggregates:
`sum(c)` for the counts, `sum(w) / sum(c)` for the average, `min(...)` of the
per-user minima, and `count(*)` for the distinct-user count. These are exact
rewrites, not approximations — no `HYPERLOGLOG` anywhere.

A separate bug in the same area, which no ClickBench query ends up hitting but
which cost time while translating them: a `DISTINCT` aggregate beside an
aggregate whose argument is an *expression* rather than a bare column fails
with `Out of range [0x80000112]`, on three rows as readily as on a hundred
million. `count(DISTINCT n), sum(n)` is fine; `count(DISTINCT n), sum(n+1)` is
not. Reported as
[taosdata/TDengine#35451](https://github.com/taosdata/TDengine/issues/35451).

## What does not run at 100M rows

A full cold sweep — `./stop`, drop the page cache, `./start`, `./check`, then
one run of each query through `./query`, which is what the shared driver does
before every cold measurement — completes 29 of the 43 queries and fails 14.
Six are refused by a hard ceiling on the number of groups, six run out of query
memory (four as the memory pool declining the query, two as a genuine
allocation failure), and two never finish.

### A hard ten-million-group ceiling

TDengine rejects a query whose aggregation produces more than ten million
groups with `Too many groups/time window in query [0x8000070A]`. Ten million
exactly is accepted; twelve million is not. There is no configuration
parameter for it, and it is not in the documentation — raised upstream as
[taosdata/TDengine#35452](https://github.com/taosdata/TDengine/issues/35452).

The ceiling is on the merged result, not on the per-vnode partial
aggregations, and spreading the data over more vgroups does not raise it: a
supertable across 32 vgroups still refuses 15M distinct keys, while 9.5M
distinct keys assembled from 19M partial groups (each key present in two
subtables) is accepted.

It is also enforced during execution rather than at planning time, so a query
that is going to be rejected still scans for two to ten minutes first.

### Grouping on a wide-declared string column

The other limit is a query memory pool, and what pushes queries into it is the
width a string column is *declared* with rather than the width of its values.
Grouping the same 3,000,000 distinct eleven-byte strings, changing nothing but
the declaration:

| Declared type | `GROUP BY v` |
| --- | --- |
| `VARCHAR(32)` | 10.4 s |
| `VARCHAR(256)` | 12.4 s |
| `VARCHAR(1024)` | 32.9 s |
| `VARCHAR(2048)` | 111.4 s |
| `VARCHAR(4096)` | `Query memory exhausted` after 307.5 s |

The growth is faster than the width: doubling 1024 to 2048 costs 3.4×, and
2048 to 4096 stops completing. Declared widths are not a free choice either,
since TDengine rejects a value longer than its declaration — `hits` forces
`URL` to `VARCHAR(8192)`, `Referer` to `VARCHAR(3072)` and `SearchPhrase` to
`VARCHAR(2048)` because those are the longest values each column actually
holds, so every string grouping here pays the multiplier. Reported as
[taosdata/TDengine#35453](https://github.com/taosdata/TDengine/issues/35453).

Which is how Q29 fails with only 3,007,986 groups, comfortably under the
ceiling: its key is `COALESCE(REGEXP_EXTRACT(...), Referer)`, which keeps the
whole `Referer` wherever the pattern does not match, making the key a
`VARCHAR(3072)`. Q15 (6.47M `VARCHAR(2048)` keys) goes the same way, while Q13
(6.02M keys on the same column) survives at 480 s and Q31 (5.73M keys, two
integer columns) at 366 s. The string cases sit either side of the edge on
this machine and both would fail on a smaller one.

`Query memory exhausted [0x8000073A]` is that pool declining to admit the
query rather than the process running out — taosd's resident set stayed at
4.3 GB while the pool refused, on a machine with tens of GB free. `Out of
Memory [0x80000102]`, which Q16 and Q34 get instead, is a real allocation
failure. Which of the two a query hits, or whether it hits the group ceiling
first, is not predictable from the query alone.

### The measured failures

| Query | Groups | Outcome |
| --- | --- | --- |
| Q5 | 17,630,976 | `Too many groups` after 390 s |
| Q9 | 17,996,642 | `Too many groups` after 120 s |
| Q10 | 17,996,642 | `Too many groups` after 238 s |
| Q14 | 10,681,408 | `Too many groups` after 546 s |
| Q15 | 6,474,212 | `Query memory exhausted` after 2,453 s |
| Q16 | 17,630,976 | `Out of Memory` after 310 s |
| Q17 | 24,070,560 | no result inside the timeout |
| Q18 | 24,070,560 | `Query memory exhausted` after 1,636 s |
| Q19 | 56,384,822 | `Query memory exhausted` after 695 s |
| Q29 | 3,007,986 | `Query memory exhausted` after 711 s |
| Q32 | 13,172,392 | `Too many groups` after 221 s |
| Q33 | 99,997,493 | `Too many groups` after 537 s |
| Q34 | 18,342,019 | `Out of Memory` after 730 s |
| Q35 | 18,342,019 | no result inside the timeout |

The closest things to survive are Q36 (9,762,046 groups, 1,021 s), Q6 and Q13
(6.0M groups on `SearchPhrase`, 864 s and 480 s) and Q31 (5.7M groups on two
integer columns, 366 s). Everything else groups well below the ceiling, either
because the key is low-cardinality (`RegionID`, `AdvEngineID`, `CounterID`) or
because a `WHERE` clause cuts the input down — Q37–Q43 filter to one counter
and run in 3–226 s.

This is the benchmark meeting the design. TDengine's aggregation is built for
windowed rollups over a bounded set of series, not for grouping a hundred
million rows by a high-cardinality string. The queries are left in their
natural form rather than approximated, so the `null`s say what the system
does.

## Loading

`INSERT INTO hits (...) FILE 'hits.csv'` is the straightforward SQL path, and
it is the one used here, but it cannot take the file whole: the `taos` client
materialises the entire statement in memory before sending anything, and the
81 GB `hits.csv` fails with `Out of Memory [0x80000102]` after about 30
seconds of parsing. 512 MB per statement works, so `load-csv.py` feeds it 128
MB at a time — small enough that the client's peak RSS (about 3.5× the chunk)
still fits on the 2 GB `t3a.small`. Each chunk is written to one scratch file
that the next chunk overwrites, so the load needs one chunk of spare disk
rather than a second copy of the dataset.

The chunk boundaries are the interesting part. `hits.csv` quotes every string
field, and 3,740 `URL` values and 2,168 `Referer` values contain literal
newlines, so splitting on `\n` corrupts rows — silently, since the fragments
still parse as numbers and strings. A newline ends a record only when an even
number of `"` characters precede it, because a quote inside a quoted field is
written doubled and never flips the parity. `load-csv.py` tracks that parity
with `bytes.count`, cuts only at even-parity newlines, and copies the input
byte for byte, so every value reaches the server with its original bytes —
including the non-UTF-8 ones `hits` contains.

`./load` finishes with `FLUSH DATABASE`. Without it the rows sit in each
vnode's write buffer, where scans are roughly an order of magnitude slower
than over committed TSDB files (`SELECT count(*)` on a 1M-row slice: 1.77 s
unflushed, 0.11 s flushed) and where `./data-size` cannot see them. It is the
TDengine-side counterpart of the `sync` the shared driver runs for every
system immediately after `./load`.

Loading is client-bound: the `taos` process spends its time turning CSV into
the wire format on a single thread while the server has cores to spare. Single
chunks measured 21–23 MB/s and the full 81 GB averaged 8.9 MB/s, both on a
machine with other tenants on it, so treat those as a floor — but expect the
load to be measured in hours, not minutes.

## What `./data-size` counts

After a full load, `dataDir` is 76.2 GB: about 40 GB of TSDB files (the
column data, its block indexes and the tag index) and about 32 GB of
write-ahead log. The WAL is that large because `WAL_RETENTION_PERIOD`
defaults to 3600 seconds — TDengine keeps the last hour of it for data
subscribers and then drops it, so the same measurement an hour later is much
smaller. `./data-size` reports the whole directory anyway: ClickBench asks for
transaction logs to be included, and this is the same thing the PostgreSQL
entry does by measuring its data directory with `pg_wal` inside.

## The primary key, and `KEEP`

The primary timestamp is `EventTime`, which is what a time-series database
indexes on and what makes Q37–Q43's date filters and Q24–Q27's `ORDER BY
EventTime` meaningful. But TDengine's primary key is `(timestamp)` and it
*overwrites* on collision, and `hits` has only 1,432,857 distinct `EventTime`
values across 99,997,497 rows — a naive load would keep 1.4% of the dataset.

TDengine 3.x allows a second column to join the primary key
(`COMPOSITE KEY`, an integer or string column), and `(EventTime, WatchID)` is
unique across all 99,997,497 rows, so `WatchID COMPOSITE KEY` makes the load
lossless — after a full load through these scripts, `SELECT count(*)` returns
exactly 99,997,497.

Separately, `KEEP` — the retention window — defaults to 3650 days, and
TDengine rejects any row whose primary timestamp is older than `now - KEEP`
with `Timestamp out of range`. `hits` is from July 2013, more than 4,600 days
ago, so at the default the entire dataset is unloadable. `./load` sets
`KEEP 36500` (the documented range is `[1, 365000]`). This is a correctness
requirement, not tuning.

## Configuration

Everything else is left at the shipped defaults — `DURATION 10d`,
`BUFFER 256`, `COMP 2`, `WAL_LEVEL 1`, `CACHEMODEL none`, `PRECISION 'ms'`,
`MAXROWS 4096`. There is no query result cache to switch off, and
`CACHEMODEL` already defaults to `none`, so no last-row cache is populated
either. What differs:

- `VGROUPS = nproc` (default 2). vgroups is how a database is sharded and how
  many query tasks a scan can run in parallel; at the default, a 96-core
  machine would scan with two threads. The vendor's
  [capacity planning guide](https://docs.tdengine.com/operations-and-tooling/operations/planning/)
  sizes it from the core count — "each CPU core can serve 1 to 2 vnodes" —
  which is what `./load` does. Memory follows
  `vgroups × (buffer + pages × pagesize + cachesize)`, about 258 MB per
  vgroup at the default `buffer`.
- `KEEP 36500` (default 3650) — see above.
- `monitor 0`, `telemetryReporting 0`, `crashReporting 0` (all default to 1).
  The first stops taosd generating the metrics that `taoskeeper` writes back
  into a database inside the same server; the other two stop outbound reports
  to the vendor. TDengine does crash during this benchmark and a benchmark run
  should not phone home about it.
- `tempDir /var/lib/taos_tmp` (default `/tmp`). This is where sorts and
  `DISTINCT` spill, and Q34's `GROUP BY URL` needs several GB of it. On Ubuntu
  25.04 and later `/tmp` is a tmpfs sized at half of RAM, so those queries
  either fail with `No space left on device` on a small instance or spill to
  RAM on a large one while every other system in the benchmark spills to disk.
  The directory sits beside `/var/lib/taos` rather than inside it so spill
  files stay out of `./data-size`.

- `queryWaitTimeout = 1800` in `taosadapter.toml` (default 900). The adapter
  aborts a query after this many seconds. 900 is too tight — Q6 takes about
  870 s at 100M rows and would be reported as a failure on a slower machine —
  but it is also the only thing bounding the queries that cannot finish at
  all: Q17 ran for a full hour without either completing or hitting a limit.
  1800 gives everything that does complete 2× headroom. `./query` gives curl
  1860 s, a minute of slack, so the server's own error surfaces rather than a
  bare client timeout.
- `taoskeeper` and `taos-explorer`, two of the four systemd units the installer
  enables, are disabled. `taoskeeper` polls `taosd` every 30 s and writes the
  results into a `log` database that would land in `./data-size`;
  `taos-explorer` is the web UI and nothing here uses it. `taosd` and
  `taosadapter` are the two that run.

`taosd` snapshots its configuration into `dataDir` on first start
(`dnode/config/*.json`) and prefers the snapshot over `taos.cfg` afterwards, so
`./install` deletes the snapshot after editing the file. Without that step the
edits show up as `cfg_file` in `taosd -C` but the old values stay in force.

Two things in the vendor's systemd unit are worth knowing and are left alone.
`Restart=always` with `StartLimitBurst=3` means systemd stops restarting
`taosd` after three crashes in fifteen minutes — `./stop` runs
`systemctl reset-failed` so the next `./start` is not a silent no-op.
And `OOMScoreAdjust=-100` shields `taosd` from the OOM killer, so on a machine
where a query outgrows RAM the kernel reaches for something else first.

## Results that differ from other engines

- **`LIKE` is case-insensitive** in TDengine, so Q21 finds 2× the rows
  ClickHouse does (`URL LIKE '%google%'` behaves like ClickHouse's
  `lower(URL) LIKE '%google%'`), and Q22–Q24 inherit the wider match. The
  queries keep `LIKE` — this is the same choice the MySQL-family entries make,
  where a case-insensitive collation does the same thing. Re-running the
  ClickHouse reference with the comparison lowered makes Q21, Q22, Q23 and
  Q24 match exactly.
- **Q4 (`avg(UserID)`) reads 2.53e18 rather than -702352578971.** `UserID`
  sums to more than `INT64_MAX` over 100M rows. ClickHouse accumulates in
  `Int64` and its answer is the wrapped sum divided by the count; TDengine
  accumulates `AVG` in something wider and returns the true average. Its own
  `SUM(UserID)` wraps to the same value ClickHouse's does, so the two engines
  disagree only about `AVG`.
- **Q18 needs the subquery it has.** Written the canonical way,
  `SELECT UserID, SearchPhrase, count(*) FROM hits GROUP BY UserID,
  SearchPhrase LIMIT 10` ignores the `LIMIT` and returns every group — 830,079
  rows on a 1% slice, and it reproduces on a 1,000-row table with 100 groups.
  Wrapping the aggregate in a subquery (`SELECT * FROM (...) LIMIT 10`)
  restores it. Q18 is the only ClickBench query with `GROUP BY` and `LIMIT` but
  no `ORDER BY`; the rest are unaffected. Reported as
  [taosdata/TDengine#35450](https://github.com/taosdata/TDengine/issues/35450).
- Q19 has no `EXTRACT`, so minute-of-hour is
  `TIMEDIFF(EventTime, TIMETRUNCATE(EventTime, 1h, 0), 1m)`, and Q43's
  `DATE_TRUNC('minute', ...)` is `TIMETRUNCATE(EventTime, 1m, 0)`.
- Q29 has no `REGEXP_REPLACE`, only `REGEXP_EXTRACT`, which returns `NULL`
  where ClickHouse's anchored `REGEXP_REPLACE` would return the input
  untouched — hence the `COALESCE(REGEXP_EXTRACT(...), Referer)`. The pattern
  uses `[.]` instead of `\.` because a backslash in a TDengine string literal
  is an escape character.
- `EventDate` is a `TIMESTAMP` at midnight; TDengine has no `DATE` type. The
  date-range predicates in Q37–Q43 compare against the same string literals
  and select the same rows.

## Upstream issues opened from this work

| | |
| --- | --- |
| [#35449](https://github.com/taosdata/TDengine/issues/35449) | `taosd` segfaults on `COUNT(DISTINCT col)` once the deduplicated set spills to disk |
| [#35450](https://github.com/taosdata/TDengine/issues/35450) | `GROUP BY ... LIMIT n` returns every group when the query has no `ORDER BY` |
| [#35451](https://github.com/taosdata/TDengine/issues/35451) | `AGG(DISTINCT x)` beside an aggregate over an expression fails with `Out of range` |
| [#35452](https://github.com/taosdata/TDengine/issues/35452) | `GROUP BY` is capped at 10,000,000 groups: undocumented, no knob, enforced only after a full scan |
| [#35453](https://github.com/taosdata/TDengine/issues/35453) | `GROUP BY` on a `VARCHAR` is priced by the declared width, not the data: 10 s at `VARCHAR(32)`, does not complete at `VARCHAR(4096)`, identical values |

## Expect a long run

Nothing here is quick. The load is a couple of hours; the 14 queries that
cannot produce a result spend two to thirty minutes each finding that out, on
every try; and the cold cycle before each query costs another 15–110 s of
`./stop` plus `./start`. A full three-try sweep is most of a day, and the
concurrent-throughput window can overrun its 600 s by up to the query timeout
because a worker that starts a doomed query just before the deadline has to
see it through. A run that looks hung probably is not.

## What has been verified

A full 100M-row load through these scripts, on a 96-core machine shared with
other work:

- 81,136,059,858 bytes of CSV loaded in 9,129 s, and `SELECT count(*)` returns
  exactly 99,997,497 — the composite primary key loses nothing.
- 6,506 subtables, one per distinct `CounterID`, and
  `information_schema.ins_tags` reports zero NULL tag values, so the
  `ALTER … SET TAG` pass covered all of them.
- `./data-size` 76,202,317,209 bytes.
- `./stop` took 111 s directly after the load, when 96 vnodes still had dirty
  write buffers, and `./start` plus `./check` 13 s. Later cycles are quicker.
- A cold sweep of all 43 queries: 29 produce a result, 14 do not, as tabulated
  above.

And on a 1,000,765-row deterministic 1% sample of `hits`, loaded through the
same scripts and compared query-by-query against `clickhouse-local` reading
the same rows:

- All 43 queries run and every result is accounted for. The only unexplained
  difference is Q4 (the `avg` accumulator above); Q21–Q24 match once the
  reference is made case-insensitive too, and the rest match exactly or up to
  ties among equal sort keys.
- Q24's ten rows agree with ClickHouse in all 1050 cells when compared by
  column name, which exercises every one of the 105 columns' types and the
  non-UTF-8 string values end to end.
- Eight queries return ten rows that are not uniquely determined — Q31, Q32,
  Q33, Q35, Q36, Q40 and Q41 all have ties at the cut, and Q18 has no
  `ORDER BY` at all — so they were re-compared with the `LIMIT`/`OFFSET`
  removed, forcing the whole grouped result to agree: 830,079 groups for Q18,
  122,335 for Q31, 131,765 for Q32, 1,000,765 for Q33, 512,806 for Q35,
  635,632 for Q36, 5,477 for Q40 and 760 for Q41. All eight match as
  multisets.

The 10,000,000-group ceiling and the `COUNT(DISTINCT)` crash were established
separately, on synthetic tables built to sit either side of each threshold,
because a 1% sample is too small to reach either.
