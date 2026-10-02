OceanBase is a distributed relational DBMS started inside Alibaba in 2010 and
open-sourced (Mulan PSL v2) in 2021. It is a shared-nothing, Paxos-replicated,
multi-tenant database with a MySQL-compatible SQL layer — `SELECT VERSION()`
answers `5.7.25-OceanBase_CE-v5.0.1.0` — and an LSM-tree storage engine. Since
4.3 that engine can store a table by column instead of by row, which is what
this entry uses; `../oceanbase-row` is the same setup with the row store, for
comparison.

This is a single-node deployment: one OBServer process, one zone, one replica.

To run the benchmark:

```
./benchmark.sh
```

## Installation

OceanBase publishes binaries as RPMs for openEuler/CentOS only, so there is no
apt repository to point Ubuntu at. That turns out not to matter: the observer
links nothing but glibc, libm, librt, libpthread, libdl and a `libaio.so.1`
that ships inside the `oceanbase-ce-libs` package. `install` unpacks the el8
RPMs with `rpm2cpio | cpio` into `/opt/oceanbase` and runs them from there.
Nothing is installed system-wide and no distribution package is touched apart
from `wget`, `rpm2cpio` and `cpio`.

Four packages are needed, all from the same mirror (`OB_MIRROR` overrides it):

- `oceanbase-ce` — the observer and `obshell`, ~1 GB unpacked;
- `oceanbase-ce-libs` — only `lib/libaio.so.1`, and without it the observer
  will not start;
- `obclient` and `libobclient` — OceanBase's MariaDB-derived CLI. Ubuntu's
  `mysql-client` speaks the same protocol, but `obclient` is the client the
  vendor ships and tests against, and it is a 23 MB download.

`install` also raises `fs.aio-max-nr` (the observer runs its data I/O through
libaio and wants more contexts than Ubuntu's default 65536 allows) and
`vm.max_map_count`, and normalises the ownership of `/opt/oceanbase` to root —
`cpio` only restores the RPM's uids when it runs as root, and the observer
refuses to start when the user starting it differs from the owner of its files.

Both `x86_64` and `aarch64` RPMs exist, so this entry runs on the `c8g.*`
machines too. The mirror also carries `nonlse` aarch64 builds for CPUs without
ARMv8.1 atomics; the Gravitons this benchmark runs on have them, so the normal
build is used.

## Bootstrapping, and why it happens in `./install`

A freshly started observer serves no tenant at all: it accepts connections but
answers `ERROR 5150 (HY000): Tenant not in this server` until
`ALTER SYSTEM BOOTSTRAP` has created the internal `sys` tenant. User data does not belong in `sys` either — it needs
a tenant of its own, which needs a resource pool, which needs a unit config.

That whole sequence has to be finished before the driver's first `./check`, so
`install` does it: start the observer, wait for `root@sys` to answer, bootstrap,
`CREATE RESOURCE UNIT` / `CREATE RESOURCE POOL` / `CREATE TENANT bench`, apply
the parameter template below, and stop again. Everything after that is a plain
`./start`.

The unit is sized from what `GV$OB_SERVERS` reports as *unassigned* rather than
from arithmetic on `memory_limit`, because the bootstrap has already given the
`sys` tenant a unit and how large that unit is depends on the version. Asking
for one core or one byte more than is free fails the `CREATE` outright with
`resource not enough to hold 1 unit`.

The bootstrap gets up to three attempts, and a failed one is reported with the
observer's own log rather than just the client's `ERROR 4015 (HY000): System
error`, which says nothing. Retrying is not simply a matter of running the
statement again: the observer decides whether it may be bootstrapped by looking
for its own leftovers, and those are spread around `$OB_HOME` rather than
confined to `store/` — `etc2/`, `etc3/`, `wallet/`, `audit/` and two generated
files in `etc/`. Leave any of them behind and the second attempt is refused with
`Server is not empty but has never been bootstrapped … has_data_version_file=
TRUE`, so `install` clears all of them between attempts.

`./check` connects to the `bench` tenant, not to `sys`. After a restart the
server answers `root@sys` well before the tenant's log stream has replayed, and
a query issued in that window fails — checking `sys` would let the driver start
timing queries too early.

## Configuration

`install` sizes the instance the way `obd`, the vendor's deployer, does:

- `memory_limit` is 80% of RAM. The observer reserves it as one arena at
  startup and never returns it, so the remaining fifth is what the page cache
  and the `hits.tsv` read during `./load` have to live in.
- `system_memory` — the slice of `memory_limit` reserved for the instance
  itself and not assignable to a tenant — follows obd's step function of
  `memory_limit` (1 GB below 12 GB, then 5, 6, 7, 8, 9, 10 GB, then 8%).
- `cpu_count` is `nproc - 2`, again as obd does — without obd's additional floor
  of 8, which on a four-core machine would tell the instance it has twice the
  cores it does.
- `datafile_size` is 35% of the free space on the filesystem, and
  `log_disk_size` equals `memory_limit`. Both are *preallocated* at first
  start, which is most of why that first start takes a couple of minutes. The
  data file has to be generous rather than merely large enough for the table:
  the sort that the direct load performs spills its runs into the same block
  manager, so at the high-water mark it holds the finished columns and the
  temporary runs at once.
  obd's automatic sizing would ask for `3 x (memory_limit - system_memory) +
  system_memory` of redo log; this benchmark writes the dataset once, through a
  path that bypasses the redo log, so `memory_limit` is plenty.
- `__min_full_resource_pool_memory` is the one knob set against the vendor
  default, and only on small machines. Every resource unit has to be at least
  this large, it defaults to 5 GB, and two of them — the `sys` tenant's and the
  benchmark tenant's — then need 10 GB on top of `system_memory`, which no
  machine under about 24 GB of RAM can spare. Where that is the case `install`
  drops it to the 1 GB floor the parameter accepts, so that
  `CREATE RESOURCE UNIT` is not rejected outright; elsewhere the default
  stands.

`install` also refuses to run below 8 GB of RAM, which is the vendor's
documented minimum, so `t3a.small` and `c6a.large` produce a one-line message
rather than an OOM kill partway through the load.

Everything else comes from `etc/default_parameter.json` and
`etc/default_system_variable.json`, files that ship inside the RPM and hold the
vendor's recommended parameter values for five workload shapes
(`express_oltp`, `complex_oltp`, `htap`, `olap`, `kv`). `install` applies the
`olap` set verbatim; `obd` and OCP offer the same thing as a dropdown when you
create a cluster and a tenant, but there is no single `ALTER SYSTEM SET
scenario` to do it in one statement, so the entries are spelled out. They are
storage-engine and optimizer defaults — column store as the default table
format, heap tables, skip-index level 1, `encoding` delta format, auto DOP, a
larger vectorized batch, bigger read batches — not rewrites of anything the
benchmark measures. `template.json` therefore says `"tuned": "no"`.

Two of them do change results, not just speed:

- `collation_server` / `collation_connection` become `utf8mb4_bin`. That makes
  `LIKE` and `ORDER BY` byte-exact, so Q21-Q24 match the same rows as
  ClickHouse does, rather than the larger case-insensitive sets the
  `utf8mb4_general_ci` default would produce (and that the `mysql` and `doris`
  entries do produce).
- `parallel_degree_policy = AUTO` lets the optimizer choose the degree of
  parallelism per query. Without it OceanBase runs each query on one thread
  unless the SQL carries a `/*+ parallel(N) */` hint, and `queries.sql` here
  carries no hints at all.

## Schema

`create.sql` is the MySQL schema with three changes.

`WITH COLUMN GROUP (each column)` is what puts the table in the column store.
It is spelled out in the DDL rather than left to the `default_table_store_format
= column` parameter the OLAP template sets, so the file says what it builds.

`ORGANIZATION INDEX` keeps the rows sorted by the primary key. The OLAP
template makes `HEAP` the default — in a heap table the primary key becomes a
separate unique index and the data is stored in arrival order — but sorting by
`(CounterID, EventDate, UserID, EventTime, WatchID)` is what every other
column store in this benchmark does with the same tuple (`DUPLICATE KEY` in
`doris` and `starrocks`, `SORT KEY` in `singlestore`, `ORDER BY` in
`clickhouse`), and it is what lets the Q37-Q42 `CounterID = 62` filter skip
most of the table.

The string columns are `VARCHAR(n)` rather than `TEXT`. `TEXT` in OceanBase is
a LOB type, and putting the benchmark's hottest columns — `URL`, `Title`,
`Referer` — behind LOB indirection in a column store would be a strange thing
for a real user to do. `VARCHAR` needs a declared width, and the widths cannot
simply all be the maximum: OceanBase caps a row at 1.5 MB of *declared* width
(4 bytes per `utf8mb4` character), which 28 `VARCHAR(65535)` columns exceed
about fivefold, and `CREATE TABLE` fails with `Row size too large`. The widths
in `create.sql` are at least four times the longest value each column actually
holds in the 100 million rows, rounded up to a power of two:

| column | longest value | declared |
| --- | --- | --- |
| `OriginalURL` | 8134 | 32768 |
| `URL` | 7391 | 32768 |
| `Referer` | 2710 | 32768 |
| `Title` | 1152 | 16384 |
| `SearchPhrase` | 1113 | 8192 |
| `Params` | 993 | 8192 |
| `OpenstatCampaignID`, `UTMCampaign`, `UTMContent`, `UTMTerm`, … | ≤ 208 | 2048 |
| `PageCharset`, `MobilePhoneModel`, `FlashMinor2`, … | ≤ 41 | 512 |
| `UserAgentMinor` | 2 | 255 |
| `HitColor` | 1 | `CHAR` |

Those are `CHAR_LENGTH`s measured in the loaded table. A 1% sample of the same
rows understates them by up to a factor of three — `Params` peaks at 315 there
against 993 over the whole dataset — so the margin is not decoration.

The three timestamp columns are `DATETIME`, not the `mysql` entry's
`TIMESTAMP`: `DATETIME` stores what the file says without a session-timezone
round trip.

## Loading

`./load` uses `LOAD DATA ... INFILE` with the `APPEND` hint, which is
OceanBase's "bypass" (direct) load: rows are converted, sorted by primary key
and written straight into major SSTables, skipping the SQL layer, the
transaction layer and the memtable. It is the documented path for an initial
bulk load, and for a columnstore table it is also what leaves the data in its
final columnar layout without waiting for a major compaction. `APPEND` is
shorthand for `direct(true, 0)` and additionally turns on online statistics
collection, so the optimizer has table and column statistics by the time the
first query arrives and there is no separate `ANALYZE` pass.

`INFILE` reads the file on the server side. `LOAD DATA LOCAL INFILE` — what the
`mysql` entry uses — cannot take the direct path at all; it is fed through the
SQL layer in protocol packets.

The `parallel(N)` degree is the tenant's core count, which is the vendor's rule,
but capped at one worker per 512 MB of tenant memory. Each direct-load worker
holds a sort area, a macroblock writer and a 7 MB coroutine stack, and on a
machine with many cores and little memory per core that adds up: at 90 workers
against a 9 GB tenant the load reached about 10 GB of data and then died with
`ERROR 4013 (HY001): No memory or reach tenant memory limit`, rolling the whole
thing back. On every machine this benchmark runs on the core count is the
smaller of the two limits and the cap changes nothing.

Server-side reads have to be inside `secure_file_priv`, and OceanBase will only
let that variable be set over a **Unix socket**, never over TCP. `install` does
it through `-S /opt/oceanbase/run/sql.sock`.

`./load` ends with a minor freeze of the user tenants *and* of the meta tenants,
and waits for it, and without that the entry produces no result at all. The
direct load leaves about a hundred megabytes of redo log on the meta tenant that
every user tenant carries, and that stream's `base_lsn` — its checkpoint —
stays at zero, so every `./start` replays the whole thing. How much replay a
tenant can buffer is bounded by its memtable, and a meta tenant's memtable is
roughly 4% of the resource unit's memory: 410 MB on a 9 GB unit. The backlog
does not fit, replay stalls with `CLOG pending size in task queue exceeds
limit`, the observer never reaches `start success`, and `./check` times out on
every one of the 43 queries. Measured on the unit whose meta tenant gets exactly
that 410 MB: without the freeze the server had not finished starting after ten
minutes, twice; with it, 27 seconds. `TENANT = all` covers the sys and user
tenants — the meta tenants need `all_meta`, which `all` does not include.

`benchmark.sh` raises the driver's `BENCH_CHECK_TIMEOUT` from 300 s to 900 s for
the same reason in reverse: the observer's start is not instant even with
nothing to replay — it re-reads its schema and tablet metadata, which after the
driver's `drop_caches` all comes off the disk — and a `./check` that times out
aborts the whole run rather than one query.

One thing to know if you reproduce this on a volume you do not have to yourself:
the load moves well over 100 GB through the disk — 75 GB of `hits.tsv` in, the
sort's runs out and back, then the merged columns — and OceanBase's failure
detector watches how long redo-log writes take. On a contended volume where
write latency reached tens of milliseconds it logged `clog disk may be hung`,
stopped log sync, and the load ended in `ERROR 4012 (HY000): Timeout` with
everything rolled back. The benchmark's own machines have the volume to
themselves and never come near this.

## Data size

`./data-size` reports `DATA_DISK_IN_USE + LOG_DISK_IN_USE` from
`GV$OB_SERVERS`, not `du` on the store directory. The observer preallocates
both the data file and the redo log pool at startup, so `du` measures the
reservation — tens of gigabytes of untouched zeroes — and would say the same
thing about an empty database as about a loaded one. The two `IN_USE` counters
are the macroblocks and log blocks actually occupied, which is the number this
benchmark asks for: user data, indexes and transaction log.

## Query results

`queries.sql` is the `mysql` entry's set with two edits. The other 41 lines are
byte-identical to `clickhouse/queries.sql`, the reference:

- Q29's `REGEXP_REPLACE` backreference is `'$1'`. OceanBase follows MySQL 8
  here, where `'\1'` is not a backreference but the literal character `1`;
  left alone, the query collapses every row into one group.
- Q43 groups by minute (`'%Y-%m-%d %H:%i:00'`). The reference query is
  `DATE_TRUNC('minute', EventTime)`; the `mysql` entry's `'%H:00:00'` truncates
  to the hour instead.

Every query was compared against `clickhouse-local` reading the same rows. 33
of the 43 agree exactly. The other ten:

- eight — Q18, Q23, Q24, Q32, Q33, Q36, Q40, Q41 — are `LIMIT` cutting through
  a run of tied sort keys, so which rows come back is arbitrary in both
  systems. Q18 has no `ORDER BY` at all; in Q32 and Q33 the sort key is
  `COUNT(*)` grouped by the unique `WatchID`, so every group ties at 1. Where
  the tie can be checked, it checks out: the multiset of sort-key values is
  identical, and in Q24 the ten `WatchID`s are the same ten.
- Q4, `SELECT AVG(UserID)`, differs because ClickHouse accumulates the
  numerator in an `Int64` and overflows. On the 1% slice it answers
  `-702352578971`, while the exact mean — which OceanBase computes in a
  decimal, and which ClickHouse reproduces if you ask it for
  `sum(toInt128(UserID)) / count()` — is `2532976247401878033`.
- Q6, `COUNT(DISTINCT SearchPhrase)`, answers 107905 against ClickHouse's
  107907 on a 1% slice. `utf8mb4_bin` is a `PAD SPACE` collation, so two pairs
  of phrases that differ only in a trailing space compare equal. This is a
  property of every MySQL-family collation available here, not of the column
  store.

## Verification

These scripts were run end to end on the full dataset. `./load` gets exactly
99,997,497 rows in and the `APPEND` hint's online statistics land with it
(`DBA_TAB_STATISTICS` reports `num_rows = 99997497`). `./data-size` reports
21.1 GiB — 11.9 GiB of columns plus 9.2 GiB of redo log — against 159 GiB of
`du` on the same directory, which is what the preallocation looks like. All 43
queries return a result, `./stop` → `./start` → `./check` → query works, and the
driver's own `bench_run_query` and `bench_concurrent_qps` were run against the
loaded table to check the integration rather than just the scripts.

Two caveats about the machine that ran it, which is a shared 96-core box, not a
benchmark VM:

- Its disk is contended, so no timing here means anything. Two earlier attempts
  at the load died on it — one with `ERROR 4013` before the parallelism cap
  described above existed, one with `clog disk may be hung`.
- 96 cores against a 9 GB tenant is about a tenth of the memory per core that
  any machine in this benchmark has. At that ratio `parallel_degree_policy =
  AUTO` picks a degree the tenant cannot afford for the three highest-
  cardinality aggregations, and Q19, Q32 and Q33 fail with `ERROR 4013`. Pinning
  the degree to 13 — what a 16-core machine would choose — runs all three:
  22.6 s, 74.6 s and 40.9 s. Nothing is capped in `queries.sql` for this; the
  parallelism policy is left where the vendor's template puts it.

The correctness comparison against `clickhouse-local` above was done query by
query on a 1% slice.

No results yet — those need runs on the benchmark's own EC2 machines.
