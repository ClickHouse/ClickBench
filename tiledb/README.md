# TileDB

[TileDB](https://github.com/TileDB-Inc/TileDB) is an embedded storage engine for
multi-dimensional arrays: a C++ library with APIs in Python, R, Java, Go and others,
which stores dense and sparse arrays as directories of immutable fragments on a local
disk or an object storage. A table is a special case of a sparse array: some columns
are its dimensions, the rest are attributes.

This entry uses the Python API, [TileDB-Py](https://github.com/TileDB-Inc/TileDB-Py),
which bundles the library.

## How the workload is expressed

TileDB has no query language. Its SQL integrations are not maintained any more: the
MariaDB storage engine (MyTile, `tiledb.sql`, also presented as "TileDB Tables") is
marked as deprecated in its repository, and the connectors for Trino and Presto are
archived. So this entry follows the convention of the other ports without SQL
(`pandas`, `dask`, `polars-dataframe`, `arcticdb`): `queries.sql` holds one Python
expression per line (the filename matches the cross-system convention, the contents
are not SQL), and `server.py` wraps the library in the HTTP interface the harness
expects.

Unlike the in-memory dataframe ports, the data does not live in the memory of the
process. It is a TileDB array on disk, `hits_array`, which survives a restart of the
wrapper, so `benchmark.sh` leaves `BENCH_DURABLE` at its default `yes` and every first
("cold") try is a read from disk after `drop_caches`.

Each query pushes as much as it can into TileDB and does the rest with the compute
functions of [PyArrow](https://arrow.apache.org/docs/python/compute.html) on the Arrow
table that TileDB-Py returns. Arrow is the form in which TileDB hands data over (its
newer SOMA API returns Arrow tables as well), so nothing is converted in between, and
no string becomes a Python object.

The names in scope for a query are in `QUERY_SCOPE` in `server.py`: `read`, `agg`,
`count`, `fetch`, `hits` and `days` are TileDB; `group`, `top`, `let`, `COUNT`, `pa`
and `pc` work on its results.

## What TileDB does and what it does not

This split is the whole story of the entry. TileDB evaluates:

- the selection of attributes: every attribute is a separate file in a fragment, and
  only the requested ones are read;
- a slice of the dimensions (`at=`): only the data tiles whose bounding rectangles
  intersect it are read. Queries 37 to 43 (`CounterID = 62 AND EventDate BETWEEN ...`)
  are such slices;
- query conditions (`cond=`): comparisons of an attribute or a dimension with a
  constant, `in`, joined with `and` / `or`. The cells that do not satisfy the condition
  are not returned, and the other attributes are read only in the tiles with a match;
- aggregates over the cells that remain: `count`, `sum`, `mean`, `min`, `max`
  (queries 1 to 3);
- the non-empty domain of the array, kept in the metadata of the fragments, which is
  `MIN(EventDate)` and `MAX(EventDate)` for a dimension (query 7).

Everything else in the workload is Arrow, on the result of the pushed-down part:
every `GROUP BY`, `COUNT(DISTINCT)`, `ORDER BY` / `LIMIT` / `OFFSET` and `HAVING`,
`LIKE` (a query condition has no pattern matching), `length`, `REGEXP_REPLACE`,
`extract(minute ...)`, `DATE_TRUNC`, `CASE`, and arithmetic on columns.

`group` is `Table.group_by` of Arrow, run on the calling thread rather than on the
thread pool of Arrow, which is its default. With the pool, the wrapper died of a
segmentation fault three times in about 500 queries, during one period of heavy load
on the machine where the entry was written (aarch64, 96 cores): in a thread of the
pool, inside Arrow's Acero, at a moment when no query was being evaluated. It did not
happen again afterwards, with or without the pool, so the cause is not established;
grouping on the calling thread takes the pool out of the picture. The pool also keeps
a hash table per thread, which took a third more memory for the keys of high
cardinality and was not faster there. So the scans are parallel (the threads of
TileDB), and the grouping is not.

A few details that shaped the queries:

- The `sum` and `mean` aggregates of TileDB saturate when a 64-bit sum overflows
  instead of failing or widening: on `UserID` they return 9223372036854775807 and
  1.797e308. So query 4 reads the column and takes the average in Arrow.
- TileDB-Py attaches every aggregate to an attribute and does not accept a dimension
  there, hence the non-empty domain in query 7.
- Its parser of conditions does not take a negative number inside `in [...]`, so
  `TraficSourceID IN (-1, 6)` is written as two comparisons joined with `or`.
- Query 24 (`SELECT * ... WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10`)
  takes two steps, because the rows are chosen outside of TileDB: the first one reads
  `URL`, `EventTime`, `WatchID` and the coordinates and finds the ten rows; the second
  one (`fetch`) reads all the columns of these rows, locating them by their
  coordinates plus a condition on `WatchID`.

## Reading

A read query of TileDB fills buffers that the caller provides and returns as many
cells as fit; the caller takes them and submits the query again for the next batch
(an "incomplete query"). `read` consumes these batches one by one and concatenates
them into one Arrow table. The `each=` argument applies a function to every batch as
it arrives, for the steps that TileDB cannot evaluate but that make the batch small
(the `LIKE` filters of queries 21 to 24, `length(URL)` of query 28), so that a column
of 100 million URLs is never held in memory as a whole.

The buffer of every field in a batch is 64 MB (`BATCH_BYTES` in `server.py`). TileDB
itself has no default for it, since the buffers are the caller's; the default of
TileDB-Py, 10 MB, makes a scan of a long string column two to three times slower.

The alternative, letting TileDB-Py run the query to completion, grows its buffers by
doubling them and needed more than twice the size of the result at the peak.

Everything else is left at its default, including the memory budget of the library
(`sm.mem.total_budget`, 10 GB) and the number of its threads.

## Schema and layout

One sparse array, `hits_array` (see `load.py`):

- dimensions: `CounterID` (`int32`) and `EventDate` (`datetime64[D]`);
- attributes: the other 103 columns, with the types of `hits.parquet`; the three
  timestamps are `datetime64[s]`, the strings are variable-length UTF-8;
- duplicates are allowed: several hits share the same coordinates.

The array is sparse because of the filters: a query condition on a sparse array
returns only the cells that satisfy it, while a dense array keeps the shape of the
slice and returns fill values for the others. A sparse array needs real columns as
dimensions, and these two are the ones the workload slices by; they are also the first
two columns of the primary key of the `clickhouse` entry.

The filters are the ones `tiledb.from_pandas` applies when not told otherwise:
Zstandard with the default level on every attribute, dimension and offsets buffer.
The cell order, the tile order and the capacity of a data tile are the defaults of the
library (row-major, 10000 cells), and no tile extent is set, so inside a fragment the
cells are sorted by (`CounterID`, `EventDate`).

## Loading

`load.py` streams `hits.parquet` and writes it in chunks of one million rows. Every
write of a sparse array creates one immutable fragment, sorted inside, so the array
ends up with about 100 fragments; a slice of the dimensions looks into each of them.
The fragments are not consolidated afterwards.

TileDB-Py takes variable-length values only as NumPy arrays of Python objects, so on
the way in every string does become a Python object. This, and the single process,
is what the load time consists of; the peak memory of the loader was 7.8 GB on a
subset of 11.8 million rows.

The athena-compatible `hits.parquet` stores its time columns as raw integers (seconds
since the epoch, and days since the epoch for `EventDate`), so they are converted on
the way in. All string values of the dataset are valid UTF-8.

## Validation

All 43 queries were run against two TileDB arrays and compared with
`clickhouse-local` on the same rows: 1.51 million rows sampled from `hits.parquet` so
that every filter matches something (all the rows of `CounterID = 62`, and every
128th of the rest), and the first 11.8 million rows of the file, loaded as 12
fragments.

On the sample, 30 came out identical. Ten more (18, 19, 23, 31, 32, 33, 39, 40, 41,
42) differ only in which of several equally ranked rows the `LIMIT` kept: for each of
them, every returned row is a member of the ClickHouse result without the `LIMIT`, and
the `ORDER BY` values of the returned rows are the same multiset as in ClickHouse.
Query 18 has no `ORDER BY` at all. On the 11.8 million rows it is 32 identical and
eight that differ in the same way.

The remaining three, on both, are differences in semantics that ClickBench already
carries across entries:

- **Query 4, `AVG(UserID)`.** ClickHouse accumulates the average of an `Int64` column
  in an `Int64`, which wraps: -4.71e12 on the sample. This entry averages in
  `float64` and returns 2.536e18, equal to `avg(toFloat64(UserID))` in ClickHouse.
- **Queries 28 and 29, `AVG(length(...))`.** `length` counts bytes in ClickHouse and
  characters here (`utf8_length`), as in DuckDB and PostgreSQL. With `lengthUTF8`
  ClickHouse returns the same numbers; the grouping, the counts and `MIN(Referer)`
  match as they are.

The regular expression of query 29 has the `(?s)` flag: `.` matches a newline in
ClickHouse, and 2168 values of `Referer` contain one.
