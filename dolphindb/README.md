# DolphinDB

[DolphinDB](https://www.dolphindb.com/) is a closed-source columnar analytical and
time-series DBMS written in C++. It combines a distributed columnar store with its
own vector-oriented scripting language, and speaks a SQL dialect on top of that
language. It is aimed at financial market data — tick, quote and order-book
workloads — and ships with matching batteries: streaming engines, factor
libraries, market-holiday calendars.

There is no separate SQL client binary. The download contains the server, a web
notebook and the script interpreter; everything else connects over the native
binary protocol through one of the language APIs (Python, Java, C++, C#,
JavaScript, R), or over the REST API. This entry uses the Python API, wrapped in
`client.py`.

## Caveats

Four, and the first two are the reason this entry looks different from its
neighbours. Each is expanded on below.

1. **The freely available license caps the server at 2 CPU cores and 8 GB of
   RAM per node, and enforces both.** Any number produced here is a number for
   2 cores, whatever the machine underneath.
2. **The results are deliberately not published.** The download is licensed
   under the DolphinDB Software Evaluation License Agreement, whose §6
   confidentiality clause covers "any information relating to the Evaluation
   Software" and whose §3 limits use to internal evaluation. Reproduction
   scripts are here in full; `results/` is gitignored, and the playground never
   serves the binary (§5 forbids distributing it to third parties).
3. **A completed 100M-row load has not been demonstrated.** The scripts and the
   43 queries are verified, and a 3.1 GB slice loads cleanly, but the only
   machine available for the full run had a filesystem another tenant was
   saturating. See *What has been verified*.
4. **Loading needs `hits.csv`, not `hits.tsv`, for correctness** — `loadTextEx`
   does not interpret ClickHouse's TSV backslash escapes and silently mangles a
   fraction of every string column — **and it needs `atomic=false`**, without
   which the load livelocks against the 8 GB ceiling.

## The community license caps the server at 2 cores and 8 GB

This is the first thing to know about any measurement this entry produces.

The zip on the download page bundles `server/dolphindb.lic`, and the vendor's
[standalone deployment tutorial](https://docs.dolphindb.com/en/Tutorials/standalone_deployment.html)
describes it as follows:

> If you have obtained the Enterprise Edition license, use it to replace the
> following file: `/DolphinDB/server/dolphindb.lic`. Otherwise, you can continue
> to use the community version of DolphinDB, which allows up to 2 nodes,
> **2 CPU cores and 8 GB RAM per node**.

Those caps are enforced, not advisory. `license()` reports
`maxCoresPerNode = 2`, `maxMemoryPerNode = 8`, `bindCPU = true`, and the server
pins itself accordingly at startup — on a 96-core machine
`/proc/<pid>/status` shows `Cpus_allowed_list: 0-1`. So on a c6a.4xlarge the
run uses 2 of the 16 available vCPUs, and on the larger machines the fraction
only gets smaller. The server will not start at all without a license file (it
exits silently, writing nothing to the log).

`./install` reads both caps out of the license file rather than hardcoding
them, so replacing `dolphindb.lic` with an Enterprise license and re-running
`./install` sizes `workerNum` and `maxMemSize` to whatever the new license
allows. Results obtained that way are a different configuration and should be
submitted separately.

## Results are not published

The download requires accepting the DolphinDB Software Evaluation License
Agreement (`README.txt`: *"Before you install and use DolphinDB, you must read
and agree to the included license agreements"*). Section 3 grants use
*"internally within Your facilities solely for the purpose of evaluation"*, and
section 6, CONFIDENTIALITY, adds:

> You may not use the Evaluation Software or any information relating to the
> Evaluation Software except for the purposes stated in Section 3 above.

There is no clause naming benchmarks specifically, but publishing measurements
is not internal evaluation. So this entry follows the ClickBench rule for
results that cannot be published (see the *If The Results Cannot Be Published*
section of the top-level README, and the `kdb` entry): the installation and
reproduction scripts are here in full, and `.gitignore` keeps `results/` out of
the repository. `./benchmark.sh` runs the whole thing unattended, so anyone can
produce the numbers for themselves.

For the same reason DolphinDB is not in the ClickBench playground: §5 of the
agreement forbids distributing "any portion of the Evaluation Software … to any
third party", and serving it from a public VM would be exactly that. It is
listed in `_EXTERNAL` in `playground/server/systems.py`, next to `kdb`.

## Schema and storage layout

`create.sql` is real DolphinDB SQL DDL — `CREATE DATABASE` and `CREATE TABLE`,
rather than the `database()` / `createPartitionedTable()` script functions most
DolphinDB examples use — so the schema lives in the file ClickBench expects it
in.

One DFS database, `dfs://clickbench`, holding one table, `hits`, with all 105
columns. Type mapping from the reference schema:

| ClickBench      | DolphinDB  |
| --------------- | ---------- |
| `BIGINT`        | `LONG`     |
| `INTEGER`       | `INT`      |
| `SMALLINT`      | `SHORT`    |
| `TIMESTAMP`     | `DATETIME` |
| `Date`          | `DATE`     |
| `TEXT`, `CHAR`  | `STRING`   |

`DATETIME` is second precision, which is all `EventTime` carries.

The table is `PARTITIONED BY EventDate` with a `VALUE` partition per day. The
dataset spans 2013-07-02 to 2013-07-31, so that is 30 partitions of ~3.3M rows
and a few hundred MB each, inside the range DolphinDB's
[data partitioning guide](https://docs.dolphindb.com/en/Database/data_partitioning.html)
asks for ("we recommend the size of a partition be between 100MB and 1GB"), and
it is also what makes the date range predicate in Q37–Q43 prunable. Partitioning
is the only physical organisation used: no sort columns, no secondary indexes,
no precomputation.

Two deliberate non-choices:

- **The OLAP engine, not TSDB.** DolphinDB has two storage engines. OLAP is the
  plain partitioned column store; TSDB is an LSM tree with mandatory
  `sortColumns`, aimed at point and range lookups on a time key. TSDB's
  `sortColumns` would be the natural home for a ClickBench primary key, but its
  sort-key index is held in memory, and 8 GB is not much room for one over
  100M rows. OLAP is also the default engine and the better fit for a workload
  that is mostly full and filtered scans.

- **`STRING`, not `SYMBOL`, for text columns.** `SYMBOL` is DolphinDB's
  dictionary-encoded string type and would make `GROUP BY URL` and friends
  considerably faster, but per
  [DolphinDB Limits](https://docs.dolphindb.com/en/Database/limits.html) the
  dictionary is per partition and holds at most 2,097,152 distinct values —
  which `URL` and `Title` are not obviously under at 3.3M rows per partition.
  Using `SYMBOL` for the low-cardinality columns only is what DolphinDB
  recommends in production and would make a reasonable `dolphindb-tuned` entry;
  the reference `create.sql` gives every text column the same string type, so
  this one does too.

## Loading: CSV, not TSV

`hits.csv` is used rather than `hits.tsv`, and the reason is correctness, not
speed.

ClickBench's TSV is written by ClickHouse's `TabSeparated` format, which escapes
`\t`, `\n`, `\r`, `\b`, `\f`, `\0`, `\'` and `\\` with backslashes inside string
fields. `loadTextEx` does not interpret those escapes: it splits on the
delimiter and takes the bytes as they are. Nothing fails — the row count is
right and no error is reported — but every affected value silently differs from
the value every other ClickBench entry sees. Measured on a 1% sample of the
dataset, that is 7331 rows of `Title`, 520 of `URL`, 375 of `Referer` and 324 of
`SearchPhrase` per million, and the visible symptom is Q26 (`ORDER BY
SearchPhrase LIMIT 10`) returning ten rows that the reference does not contain,
because the 36 search phrases per million that begin with `'` arrive as `\'`
instead.

`hits.csv` is written by the `CSV` format, which quotes strings with `"` and
doubles internal quotes instead of using backslashes. `loadTextEx` reads that
correctly, including the ~0.006% of rows whose `URL` contains a raw newline
inside the quoted field (1,000,765 records arrive from a 1,000,823-line file).
With CSV, Q26 and Q24 match the reference exactly.

The load is a single `loadTextEx` call over the single file, which parses and
writes into the partitioned table directly. It needs the column names and types
up front, because the file has no header row; `client.py` reads them back out of
the table that `create.sql` just created, so the schema is stated in one place.

### `atomic=false` is not optional here

`loadTextEx` takes an `atomic` flag, and the reference is explicit about when
you need it:

> It is required to set `atomic = false` if the file to be loaded exceeds the
> cache engine capacity. Otherwise, a transaction may get stuck: it can neither
> be committed nor rolled back.

81 GB of CSV against the shipped `OLAPCacheEngineSize=2` (GB) is very much
"exceeds the cache engine capacity", and leaving the flag out reproduces the
documented failure exactly. About six minutes and 5 GB into the file, resident
memory pins itself to the license's 8 GB ceiling and the server log starts
repeating, once a second and indefinitely:

```
<WARNING> :[TabletCache::flushContext ] come across an exception : std::bad_alloc, and will retry later.
```

The load neither fails nor progresses — it livelocks, and `SIGTERM` will not
shift it. `client.py` passes `atomic=false`, which splits the file into 128 MiB segments
(the server logs `loadTextEx size per partition : 134217728, partitions : 605`),
commits each as its own transaction, and holds resident memory around 5 GB. It
also keeps the redo log near empty, because each commit retires its own log
records instead of accumulating them until the end.

If a run *is* killed in that state, note that the restarted server rolls the
partial transaction back but can be left unable to drop the database
(`dropDatabase(...) => No available replica for the chunk
FileBlock[/clickbench/domain, ...]`). `rm -rf db` and start over; a normal
benchmark run begins from an empty `db/` anyway.

## Query dialect notes

DolphinDB SQL is close enough to the reference queries to keep them recognisable,
but seven things had to change. Each is a dialect difference, not a rewrite of
what the query measures. `<>`, `HAVING`, `CASE WHEN ... THEN ... ELSE ... END`
and scalar subqueries in `FROM` all work as in standard SQL.

1. **`COUNT(DISTINCT x)` → `nunique(x)`.** `count(distinct x)` is rejected with
   *"Cannot nest aggregate function"*, and so is every variant of it
   (`size(distinct x)`, `exec count(distinct x)`). `nunique` is the exact
   distinct-count aggregate; its results match `uniqExact` on every query that
   uses it (Q5, Q6, Q9, Q10, Q11, Q12, Q14, Q23).

2. **Aggregates cannot appear in `ORDER BY`.** `ORDER BY COUNT(*) DESC` is a
   syntax error, so the count is aliased in the select list and ordered by the
   alias (Q8, Q16, Q17, Q19).

3. **Grouping expressions are aliased in `GROUP BY`, not in `SELECT`.** A
   `GROUP BY` on an expression auto-names the key, and the same expression
   repeated in the select list is then *"Unrecognized column name"*. So
   `GROUP BY <expr> AS k` and select `k` (Q19, Q29, Q36, Q40, Q43).

4. **`LIMIT n OFFSET m` → `LIMIT m, n`**, and on a DFS table an offset cannot
   be combined with `GROUP BY` at all: *"For a distributed query, the TOP or
   LIMIT clause cannot specify an offset when used with GROUP BY clause."* So
   Q39–Q43 wrap the aggregation in a subquery and apply the offset outside it.

5. **`=` inside a function call is a keyword argument.** This is why Q40 uses
   `CASE WHEN`, which DolphinDB supports, rather than the equivalent
   `iif(...)`: written as `iif(SearchEngineID = 0 and AdvEngineID = 0, ...)`
   the comparison is parsed as passing `SearchEngineID` by name and rejected
   ("If one argument is passed as keyword argument, all subsequent arguments
   must also be passed as keyword arguments"). Inside a call, equality has to
   be spelled `==`. Bare `WHERE CounterID = 62` is unaffected.

6. **`NOT` binds looser than `AND`.** `Title LIKE ... AND NOT URL LIKE ... AND
   SearchPhrase <> ''` parses as `NOT (like AND <>)`, which quietly lets rows
   with an empty `SearchPhrase` through and returned 354 rows where the
   reference returns 70. Q23 parenthesises it: `AND NOT (URL LIKE '%.google.%')`.
   `LIKE` itself matches SQL: `%` and `_` are the wildcards and `.` is a
   literal.

7. **Function names.** `length` → `strlen`, `extract(minute FROM t)` →
   `minuteOfHour(t)`, `DATE_TRUNC('minute', t)` → `bar(t, 60)`, date literals
   `'2013-07-01'` → `2013.07.01`. `REGEXP_REPLACE` → `regexReplace`, whose
   engine takes `$1`-style backreferences but rejects the non-capturing group in
   the reference pattern (*"Could not compile regular expression"*), so Q29 uses
   `^https?://(www[.])?([^/]+)/.*$` with `$2` — the same match, one extra
   capture group.

One query could not keep its original shape at all: **Q35**
(`GROUP BY 1, URL`), because `GROUP BY 1` is *"Invalid grouping column [1]"*.
Since the first select item is the constant `1`, grouping by `URL` alone is
equivalent, and the constant is kept in the select list.

All 43 queries were checked against `clickhouse-local` running
`clickhouse/queries.sql` over the same 1% sample of the dataset. 30 match row
for row; Q14, Q16, Q19 and Q22 return the same set of rows in a different order
among equal sort keys. The other nine differ only in ways the queries themselves
permit: Q18 has no `ORDER BY` at all; Q23, Q31, Q32, Q33, Q36, Q40 and Q41 order
by a count that has more ties than the `LIMIT` cuts at (in Q32 and Q33 every
group has count 1, so any ten rows are correct); and Q10's `AVG` differs in the
fifth significant digit.

## What has been verified

Worth stating plainly, because the license cap makes this entry unusual:

- The script set runs end to end — `install`, `start`, `check`, `load`,
  `query`, `data-size`, `stop` — and the harness's stop / drop_caches / start
  cold cycle works against it.
- All 43 queries were diffed against `clickhouse-local` on a 1% sample of the
  dataset, as described above.
- The `atomic=false` requirement was found by loading the real 81 GB
  `hits.csv`, and a 3.1 GB slice of it (24 of the 605 segments) loads cleanly
  at ~17k rows/s.

What has *not* been established is a completed 100M-row load, because the only
machine available for it was a shared box whose disk another tenant was
saturating. DolphinDB syncs on every segment commit with the shipped
`dataSync=1`, `sync()` waits on the whole filesystem's dirty pages rather than
just its own, and the server log showed single `syncAll` calls taking 157
seconds. That also produces a startup failure mode worth knowing about: a
thread stuck in `sync_inodes_sb` survives `SIGKILL` and keeps port 8848 bound,
so the next `./start` dies with "Failed to bind the socket on port 8848".
`./stop` therefore waits for the socket to be released and not merely for the
process to leave, and `./start` reports an immediate exit on stderr instead of
leaving the caller to time out.

None of that is expected on a dedicated benchmark VM with its own volume, but
it has not been demonstrated there either.

## Caching and the cold runs

The harness's own cold cycle applies without special handling: `./stop` sends
SIGTERM so the cache engine is flushed and chunks are closed cleanly, the
process exits, the page cache is dropped, and `./start` brings up a fresh
server. DolphinDB has no query result cache to disable — the configuration
reference has no such setting — and `chunkCacheEngineMemSize`
(`OLAPCacheEngineSize` in the shipped config) is a write-side buffer, not a
result cache.

## Configuration

`./install` generates `clickbench.cfg` from the `dolphindb.cfg` that ships
inside the package — the vendor's own standalone configuration, kept as-is —
overriding only `workerNum`, `localExecutors`, `maxBatchJobWorker` and
`maxMemSize`, which have to track the machine and the license. The shipped file
hardcodes `workerNum=4` and `maxMemSize=32`, and DolphinDB's defaults for them
are `nproc` and ~80% of RAM; neither is right when the license pins the process
to 2 cores and 8 GB.

`./start` also raises the process's open-files soft limit to 102400 before
exec'ing the server, which the vendor's
[machine preparation tutorial](https://docs.dolphindb.com/en/Tutorials/prep_linux_for_deploy.html)
asks for ("the number of files open simultaneously when running DolphinDB may
exceed the default maximum number 1024"). It needs no privileges — Ubuntu's
hard limit is 1048576 — and 30 partitions x 105 columns is well past 1024.

Everything else is left at the vendor's values, including `dataSync=1`,
`OLAPCacheEngineSize=2` and `perfMonitoring=true`. (The shipped file is not
byte-identical across architectures — the x86-64 package also sets
`enableDFSQueryLog` and `enableAuditLog` — but `./install` filters rather than
rewrites, so whatever the package ships is what gets used.)

## `data-size`

`du -sb db`, the `-home` directory, which is everything the server persists:
the column chunks and their metadata under `db/local8848/storage`, the DFS
catalog in `dfsMeta`, and the redo logs in `db/local8848/log/{redoLog,TSDBRedo,
PKEYRedo,recoverLog}`. The server's own text log is not in there — DolphinDB
writes `dolphindb.log` next to the binary, not under `-home` — so this is data
and write-ahead log only.

In practice the write-ahead log contributes almost nothing to the reported
number. It does grow during the load — DolphinDB only purges persisted
transactions from it every `redoLogPurgeInterval` (10 s) or once it passes
`redoLogPurgeLimit` (4000 MB) — but a clean shutdown drains it, and the harness
reads `./data-size` after the 43 per-query stop/start cycles, by which point
`local8848/log/redoLog` is empty and the figure is chunks plus metadata.

## Versions and architectures

`DOLPHINDB_VERSION` defaults to 3.00.6. The package name differs by
architecture: x86-64 downloads `DolphinDB_Linux64_V<version>.zip` and arm64
`DolphinDB_ARM64_V<version>_ABI.zip`, which is the only arm64 flavour published
(`_ABI` means built with `_GLIBCXX_USE_CXX11_ABI=1`, which matters for plugin
linking, not for the engine). The arm64 package is also much smaller because it
omits the optional plugins — parquet, AWS, HDF5, MySQL — none of which this
entry uses.
