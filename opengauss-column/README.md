This is the `opengauss` entry with one change: `hits` is created
`WITH (ORIENTATION = COLUMN)`, so it lives in openGauss's column store and is
read by its vectorized executor instead of the row-at-a-time one. openGauss
documents the column store as the storage for "data warehouse services with a
large amount of aggregation computing", which is what ClickBench is.

Read `../opengauss/README.md` first: installation from the openEuler tarball,
the two bridged sonames, the `omm` user, `DBCOMPATIBILITY = 'PG'`, the way
files reach `gsql` on stdin, and the `query_dop` / `max_connections`
relationship are all identical here and are only described there.

To run the benchmark:

```
./benchmark.sh
```

## What differs from the row-store entry

- `create.sql` ends in `) WITH (ORIENTATION = COLUMN);`. openGauss accepts
  every type the portable ClickBench schema uses in a column-store table, so
  the schema is otherwise byte-for-byte the `postgresql` one. Compression is
  left at the column store's default of `low`; `middle` and `high` exist and
  would trade CPU for space.
- Nothing else. `install` is byte-for-byte the row-store entry's, including
  `shared_buffers`: `cstore_buffers`, the CU cache the column store reads
  through, is deliberately left at its default, because the driver restarts
  the server and drops the page cache before every query, so a large CU cache
  is never warm when it matters. An earlier revision of this entry gave it a
  quarter of RAM and the c6a.4xlarge run spent about 30 minutes in each cold
  cycle -- 18 queries in ten hours, against 156 seconds of actual query time.
- `./load` finishes with `ANALYZE` rather than `VACUUM ANALYZE`: there are no
  heap pages to freeze and no visibility map to build.

## What the column store is worth

Loaded with the same 99,997,497 rows through the same scripts, the column
store takes 16 GB for the table and 31.3 GB for the whole data directory,
against 86.6 GB for the row store, and it loads in a little over half the
time.

Per query it is not uniformly better, which is the interesting part. It is
two to three orders of magnitude faster on the selective tail of the workload
— Q37 to Q43, which filter on `CounterID` and an `EventDate` range, drop from
229-303 s each to between 0.16 s and 1.8 s, because those queries read five or
six of the 105 columns where the row store has to walk every one of them. Q1
and Q20 finish in 65 ms.

It is *slower* than the row engine on `COUNT(DISTINCT ...)`. The scan is not
the problem: on a 1% slice, `SELECT COUNT(DISTINCT UserID)` spends 6 ms in
`CStore Scan` and 1.27 s in `Vector Aggregate`, where the row plan does the
whole thing in 0.38 s. Eight of the 43 queries use `COUNT(DISTINCT ...)` and
all eight pay this.

## A constant in the GROUP BY costs an order of magnitude

Q34 and Q35 differ only in that Q35 adds a constant to the grouping list:

```sql
SELECT    URL, COUNT(*) AS c FROM hits GROUP BY    URL ORDER BY c DESC LIMIT 10;  -- Q34
SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;  -- Q35
```

The plans are structurally identical — `CStore Scan`, `Vector Sonic Hash
Aggregate`, `Vector Streaming(LOCAL REDISTRIBUTE)`, a second aggregate, sort,
limit — and differ in exactly one line, which `EXPLAIN VERBOSE` shows on the
redistribution:

```
Q34:  Distribute Key: url
Q35:  Distribute Key: (1)
```

The planner keys the redistribution on the leading grouping column, and for
Q35 that column is the constant, so every row hashes to the same worker and
the other 47 have nothing to do. Measured back to back on the full 100M rows
with `query_dop = 48`:

| query | `query_dop = 48` | `query_dop = 1` |
| --- | --- | --- |
| Q34, `GROUP BY URL` | 50.9 s | 456.1 s |
| Q35, `GROUP BY 1, URL` | 636.6 s | 397.6 s |
| Q35 rewritten, `GROUP BY URL, 2` | 22.5 s | |

Parallelism is worth 9x to Q34 and nothing at all to Q35 — at `query_dop = 48`
Q35 is in fact slower than at `query_dop = 1`, since it pays for the
redistribution and gets no distribution out of it. Moving the constant to the
end of the grouping list restores `Distribute Key: url` and, with it, the
runtime.

The query is left exactly as ClickBench specifies it. This is worth reporting
to the openGauss community; it has not been filed yet.

## An aggregate `FILTER` clause takes the instance down

Not a ClickBench query — none of the 43 uses `FILTER` — but found while
measuring this dataset, and worth knowing about before anyone else spends an
evening on it. On a column-store table, an aggregate with a `FILTER` clause
kills the whole `gaussdb` instance, silently: no log entry, no core, every
session gets `connection to server was lost`, and the next start does redo
recovery. 1000 rows are enough:

```sql
CREATE TABLE t_col (a int, b int) WITH (ORIENTATION = COLUMN);
INSERT INTO t_col SELECT i, i % 7 FROM generate_series(1, 1000) i;
SELECT count(*) FILTER (WHERE b = 1) FROM t_col;   -- instance gone
```

The same statement against a row-store table answers normally, so it is the
vectorized path. Also unfiled.

## Verification

These scripts were run end to end on the full dataset: `./load` gets exactly
99,997,497 rows in and all 43 queries return a result, none erroring or timing
out. Every one of the 43 was then compared against the row-store entry's
answers for the same 100M rows — the two execution engines agree on 34 of them
exactly, and the 9 that differ are all queries where a `LIMIT` cuts through a
run of tied sort keys (Q18 has no `ORDER BY` at all). Correctness against
`clickhouse-local` was checked query by query on a 1% slice, as described in
`../opengauss/README.md`.

No results yet — those need runs on the benchmark's own EC2 machines.
