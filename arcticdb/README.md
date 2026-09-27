# ArcticDB

[ArcticDB](https://github.com/man-group/ArcticDB) is an embedded, versioned DataFrame
store from Man Group: a C++ storage and query engine with a Python API, backed by
LMDB on a local disk or by S3 / Azure / MongoDB. It is aimed at time-series data —
you write pandas DataFrames into named *symbols* inside a *library*, every write
creates a new version, and you read back a DataFrame.

## How the workload is expressed

ArcticDB has no SQL. From its own FAQ: *"No. ArcticDB enables data access and
modifications with a Python API that speaks in terms of Pandas DataFrames."*
So this entry follows the convention of the other dataframe ports (`pandas`,
`dask`, `polars-dataframe`): `queries.sql` holds one Python expression per line —
the filename matches the cross-system convention, the contents are not SQL — and
`server.py` wraps the library in the HTTP interface the harness expects.

Unlike those ports the data does not live in process memory. It is in an on-disk
LMDB store under `store/`, which survives a restart of the wrapper, so
`benchmark.sh` leaves `BENCH_DURABLE` at its default `yes` and every first
("cold") try is a genuine read from disk after `drop_caches`.

Each query pushes as much as it can into ArcticDB's `QueryBuilder`, which the
engine evaluates over the stored segments, and finishes the rest in pandas on the
(usually much smaller) result. The names in scope are `read`, `col`, `let`, `Q`,
`where`, `lib`, `SYMBOL` and `pd`; see `server.py`.

## What QueryBuilder can and cannot do

This split is the whole story of the entry, so it is worth stating exactly. The
engine evaluates:

- filters — `< <= > >= == !=`, `~`, `& | ^`, `isin`/`isnotin`, `isna`/`notna`, and
  `regex_match`, which is a PCRE2 unanchored search and therefore covers
  `LIKE '%…%'` (and `NOT LIKE` under `~`);
- projections — `q.apply(name, expr)` over `+ - * / **`, unary `-`, `abs` and the
  two-branch `where()` ternary. That operation set is the entire expression
  language: there is no modulo, no cast, no string function, no date function;
- `groupby(name).agg(...)` — **one** grouping column, and exactly five aggregators
  (`sum`, `mean`, `min`, `max`, `count`). `min`/`max` are numeric/bool only, so
  `MIN(URL)` is not expressible; `count` does work on strings;
- `resample(rule).agg(...)`, but only on a datetime-indexed symbol;
- `head`/`tail`/`row_range`/`date_range`, all positional.

Everything else in the workload is pandas, on the result of the pushed-down part:
every `ORDER BY`/`LIMIT`/`OFFSET` (there is no sort clause at all), every
`COUNT(DISTINCT)`, every multi-column `GROUP BY`, `HAVING`, `MIN(URL)`/`MIN(Title)`/
`MIN(Referer)`, `length()`, `REGEXP_REPLACE`, `extract(minute …)` and
`DATE_TRUNC('minute', …)`.

`q.concat()` exists but is a vertical union of several symbols, not a relational
join; the benchmark is a single flat table, so it is not used.

## Schema and layout

One library, one symbol `hits`, 105 columns, static schema.

The symbol is stored with a plain **`RangeIndex`**. ArcticDB keeps a RangeIndex as
`(start, step)` metadata and writes no index column, so it costs nothing, and the
`EventTime` / `EventDate` columns stay ordinary columns that filters and
aggregations can reach.

A `DatetimeIndex` on `EventTime` would have been the idiomatic ArcticDB choice, and
would have unlocked `date_range` pruning for queries 37–43 and `resample('min')`
for query 43. It is not used because the dataset is not time-ordered: getting there
means `sort_and_finalize_staged_data`, which "requires performing a full sort in
memory" — 100M rows × 105 columns, far past the RAM of the machines this benchmark
runs on. Chunked `append` cannot do it either, since it only accepts data whose
first index is at or after the last index already stored.

`LibraryOptions(columns_per_segment=1)` is the one option that departs from
ArcticDB's defaults. ArcticDB tiles a symbol across both rows and columns and reads
only the segments a query asks for, but the default tile is 127 columns wide —
wider than `hits` — so the whole table would land in a single column slice and
`columns=[...]` would prune nothing off disk, making every query a full-table read.
One column per segment gives the columnar layout the documentation describes.
`rows_per_segment` is left at its default 100,000.

Two related facts worth knowing when reading the code:

- for a filter-only or projection-only query, `columns=None` makes ArcticDB decide
  that *every* column is required, so the column list must always be passed
  explicitly;
- `columns=[...]` may **not** be passed alongside a `groupby().agg()` query —
  ArcticDB rejects it with *"Cannot combine provided clauses with column
  selection"* — and does not need to be, because it prunes to the clause's own
  input columns automatically.

## Loading

`hits.parquet` is streamed in 1M-row batches: the first becomes `lib.write`, the
rest `lib.append`, each with an explicit contiguous `RangeIndex` (an append that
does not continue the previous range is rejected). The whole DataFrame passed to a
single write has to fit in RAM, which is the upper bound on the batch size; the
lower bound is that every append rewrites the symbol's index key listing every
segment written so far, so the cost of those rewrites grows with the square of the
number of appends. Following the file's own 226 row groups would mean 226 appends,
so batches are buffered up to 1M rows first, giving ~100.

The athena-compatible `hits.parquet` stores its time columns as raw integers
(seconds since epoch, and days since epoch for `EventDate`) rather than parquet
logical types, so they are converted on the way in.

`stage()` + `finalize_staged_data()` is ArcticDB's parallel bulk-load path and would
be faster, but its documented contract is about non-overlapping *timeseries*
indexes and says nothing about row-count-indexed symbols, so the load uses plain
`append`.

## Validation

All 43 queries were run against a real ArcticDB store (1.15M rows sampled from
`hits.parquet` so that every query's filters match something, including the
`CounterID = 62` July-2013 window and the specific `RefererHash`/`URLHash`
constants) and diffed against `clickhouse-local` on the same sample.

29 came out identical. Ten more (18, 19, 23, 31, 32, 33, 39, 40, 41, 42) differ
only in which of several equally-ranked rows the `LIMIT` kept: for each of those,
every row this entry returns is a member of the *unlimited* ClickHouse relation,
and the `ORDER BY` values of the ten selected rows are the same multiset as
ClickHouse's — so the grouping and the aggregates agree and only the
SQL-unspecified tie-break differs. Query 18 has no `ORDER BY` at all.

The remaining three are real semantic differences, both of a kind ClickBench
already carries across entries:

- **Query 4, `AVG(UserID)`.** ClickHouse accumulates `avg` over an `Int64` column
  in an `Int64`, which wraps: `sum(UserID)` on the sample is
  -5186055357340185114 and `avg` is -4.50e12. pandas accumulates in float64 and
  returns 2.54e18, which is `avg(toFloat64(UserID))` in ClickHouse and the
  mathematically correct mean. Nothing here can produce the wrapped value short
  of deliberately overflowing.
- **Queries 28 and 29, `AVG(length(...))`.** ClickHouse's `length()` counts bytes;
  `Series.str.len()` counts characters, and the URLs are full of multi-byte UTF-8,
  so the average comes out 91.94 against ClickHouse's 93.16. The grouping, the
  counts and `MIN(Referer)` all match exactly. This follows `pandas`, `dask` and
  `polars-dataframe`, and DuckDB and PostgreSQL likewise count characters;
  byte-exactness would mean encoding every string a second time inside the timed
  query.

Query 29 does need `re.DOTALL` to reproduce ClickHouse's regex dialect, whose `.`
matches a newline where Python's does not — five of the sample's non-empty
`Referer` values contain one, and without the flag the anchored pattern stops
matching and they drop out of their group (510421 rows instead of 510426).

## Notes

- **There is no Linux aarch64 wheel.** PyPI publishes `manylinux2014_x86_64` only
  (plus macOS arm64 and Windows amd64), so `./install` fails fast on a Graviton
  machine rather than letting pip attempt a vcpkg source build. conda-forge does
  ship `linux-aarch64`, but lags behind.
- **Compression is not configurable.** ArcticDB always encodes with LZ4
  (`acceleration = 1`); the `VariantCodec` protobuf has a ZSTD arm but nothing in
  the library config or runtime config reaches it. Strings are stored as offsets
  into a per-segment string pool, i.e. dictionary-encoded per segment.
- The `map_size` in the LMDB URI (400 GB) is a ceiling, not an allocation: LMDB
  reserves that much virtual address space and grows `data.mdb` into it on demand,
  so the file tracks the data (a 40 GB map over 250 MB of data leaves a 250 MB
  file). `./data-size` uses `du`, i.e. blocks actually allocated;
  `lib.admin_tools().get_sizes_for_symbol("hits")` came out ~2% lower on a
  sample load, the difference being LMDB's own B-tree overhead.
- ArcticDB is licensed under the **Business Source License 1.1** (Apache-2.0 two
  years after each release), not an OSI-approved licence. `proprietary` is `no`
  here, following `cockroachdb`, which is also BSL.
- The library is opened once per process: LMDB refuses to have the same path opened
  twice from one process.
- `SELECT COUNT(*)` is answered by reading one column rather than from
  `lib.get_description(symbol).row_count`, which would return it from metadata
  without touching the data. `lib.read(symbol, columns=[])` would do the same:
  ArcticDB short-circuits an empty column list on a row-count-indexed symbol.
