openGauss is an open-source (Mulan PSL v2) relational DBMS released by Huawei
in 2020 and now developed in the openGauss community. Its kernel is a fork of
PostgreSQL 9.2.4 — `SHOW server_version` still answers `9.2.4` — rewritten in
C++ and extended with a thread-per-session model, a vectorized executor, a
column store, and the in-memory MOT engine.

This entry uses the row store, which is what a plain `CREATE TABLE` gives you.
`opengauss-column` is the same setup with `ORIENTATION = COLUMN` tables, which
is what the vendor documentation prescribes for OLAP; see the numbers in that
directory's README.

To run the benchmark:

```
./benchmark.sh
```

## Installation

openGauss publishes binaries for openEuler and CentOS only, so there is no apt
repository to point Ubuntu at. `install` downloads the 6.0.5 LTS *openEuler
20.03* server tarball — published for both `x86_64` and `aarch64` — which is
built against glibc 2.28 and runs unmodified on Ubuntu once two sonames are
bridged:

- `libaio.so.1`, which Ubuntu renamed to `libaio.so.1t64` in the 64-bit
  `time_t` transition. That transition is an ABI no-op on a 64-bit machine, so
  the symlink is safe.
- `libreadline.so.7`, where Ubuntu ships readline 8. Only `gsql` links it, and
  only for interactive line editing, which the benchmark never does.

Both symlinks live in `/opt/opengauss/compat`, which is on `LD_LIBRARY_PATH`;
nothing outside `/opt/opengauss` is touched. Everything else the binaries need
that isn't glibc — OpenSSL 1.1, libxml2, libcurl, libstdc++, Kerberos — is
bundled in the tarball's own `lib/`.

The server refuses to run as root, so `install` creates the conventional `omm`
user, and every other script reaches the database through
`sudo -u omm /opt/opengauss/run`, a wrapper written at install time that
sources `GAUSSHOME`, `LD_LIBRARY_PATH`, `PGDATA`, `PGPORT` and `PGHOST`.

## `DBCOMPATIBILITY = 'PG'`

`./load` creates the database with `DBCOMPATIBILITY = 'PG'`, and that is not
cosmetic. openGauss defaults to `'A'` (Oracle) compatibility, in which the
empty string *is* NULL. Under the default the load stops on the first row of
`hits.tsv`:

```
ERROR:  null value in column "referer" violates not-null constraint
```

and had the schema not been `NOT NULL` throughout, the loss would have been
silent instead: the 16 queries that filter on `<> ''` would have been
comparing against NULL and matching nothing, and the affected columns are not
marginal — 94.4% of `MobilePhoneModel`, 86.8% of `SearchPhrase`, 19.0% of
`Referer` and 14.9% of `Title` are the empty string in this dataset. `'PG'`
mode restores PostgreSQL's semantics, which is what the rest of this benchmark
assumes.

## Loading

The benchmark VMs check the repository out under root's home directory, which
`omm` cannot traverse, so `./load` hands `create.sql` and `hits.tsv` to `gsql`
on stdin instead of by path. Server-side `COPY FROM '<file>'` and client-side
`\copy` load at the same speed here, so nothing is lost by doing it this way.

As in the `postgresql` entry, the `TRUNCATE` and the `COPY ... WITH (FREEZE)`
share one transaction — openGauss keeps PostgreSQL's rule that a table has to
have been created or truncated in the current subtransaction for `FREEZE` to
be accepted.

## Configuration

`install` sets the same knobs as the `postgresql` entry, sized from
`MemTotal`: `shared_buffers` at a quarter of RAM, `effective_cache_size` at
three quarters, `work_mem` at 64 MB. Two of them are openGauss-specific:

- `max_process_memory` is a hard ceiling on everything the instance allocates,
  and it defaults to 12 GB no matter how large the machine is. Left alone it
  would cap a `c7a.metal-48xl` at a twelfth of its RAM; set too high it invites
  the OOM killer instead. `install` uses 80% of RAM, floored at the 2 GB the
  GUC accepts as its minimum.
- openGauss has no `max_wal_size`; the pre-9.5 `checkpoint_segments` is still
  the knob, and 2048 segments is the same 32 GB the `postgresql` entry
  allocates.

## Parallelism

openGauss runs a query on one thread unless `query_dop` is raised above its
default of 1, and the difference is not marginal. Measured back to back on a
1% slice of the dataset, moving from `query_dop = 1` to `query_dop = 8` took
Q34 (`GROUP BY URL`) from 20.5 s to 0.87 s, Q30 (90 `SUM`s over one column)
from 5.4 s to 0.70 s, and Q21 (`URL LIKE '%google%'`) from 0.35 s to 0.05 s.
`install` therefore sets `query_dop` to half the thread count, the same share
of the machine the `postgresql` entry gives `max_parallel_workers_per_gather`.

Raising it has a consequence the stock configuration does not survive: every
thread of a parallel plan occupies a connection slot, so the driver's
10-connection throughput test wants roughly `10 x query_dop` of them at once
and, against the default `max_connections = 200`, every worker gets

```
FATAL:  No free proc is available to create a new connection
```

`install` sizes `max_connections` from `query_dop` for that reason.

## Queries

The 43 queries are the `postgresql` entry's queries, unmodified — no rewrites,
no substituted functions. All 43 produce results, and every one of them was
compared against `clickhouse-local` reading the same rows: they agree
everywhere except where a `LIMIT` cuts through a run of tied sort keys, and on
`SELECT AVG(UserID)`, where openGauss accumulates the numerator in `numeric`
and returns the exact mean while ClickHouse wraps it in an `Int64`.

`LIKE` is case-sensitive here, as in PostgreSQL, so Q21-Q24 match the same
rows as in the other PostgreSQL-family entries.

## Verification

These scripts were run end to end on the full dataset: `./load` gets exactly
99,997,497 rows in, `./data-size` reports 86.6 GB, and all 43 queries return a
result — none errors, none times out. The correctness comparison against
`clickhouse-local` above was done query by query on a 1% slice.

There is nothing surprising in the shape of the result: as in the `postgresql`
entry, every query is a full sequential scan of the whole table, so on a
machine whose RAM cannot hold it the runtimes collapse onto the time it takes
to read the table off the disk. No results yet — those need runs on the
benchmark's own EC2 machines.
