# WaveDB

WaveDB (https://github.com/Winkman4000/WaveDB) is a column-oriented analytical database written in Python,
with its hot loops compiled by numba. It runs here as a small HTTP server (`wdb serve`) and every query goes
through `./query` (curl measures the round trip). Everything runs with the engine's default settings; no
environment variable is set.

**Load.** `./load` reads the single `hits.parquet` file with `wdb load`:
- `--cluster-by EventTime`: the rows are stored ordered by `EventTime` (the table's sort order, the clustered
  primary key the rules allow);
- `--cast EventDate=date_days --cast EventTime=timestamp_s`: the two integer columns become a date and a
  timestamp, as DuckDB's load does;
- `--hash URLHash,RefererHash`: a storage codec for those two columns (each row stores its code, or the
  distance back to the previous row with the same code); it replaces the column's stored codes and is only
  ever decoded -- no index, no lookup structure.

**What is on disk** (`./data-size` counts all of it): the column data; the load statistics -- per block of
rows, the smallest and largest code and the number of non-NULL rows, plus sampled entries of the block
dictionaries used to seek inside a column; and, for every large text column, the character length of each
dictionary entry and of each row (the string sizes, kept for every such column by default -- no column is
named). Each column's dictionary is its own sorted list of distinct values -- part of the column's encoding,
so `COUNT(DISTINCT col)` with no filter is that list's length, and `COUNT(*)` is the stored row count.
No index, projection, materialized view or pre-aggregated table is built, by
the load or by any query: the engine's derived-structure extension ("sidecars") is off by default, and
answering from stored sums or per-value counts is off by default (none are written). Like ClickHouse's
min/max-count projection, MIN, MAX and COUNT of a column with no filter can be answered from the per-block
minimum, maximum and non-NULL counts.

**Install.** `./install` checks out the engine at a pinned commit with pinned Python packages, then compiles
every numba kernel signature the engine uses (`tools/kernel_build.py build`, from `src/kernels.manifest`), as a
C++ engine is compiled at install. DuckDB is installed because the loader can fall back to it to read a Parquet
file; no query is ever executed by DuckDB on this setup.

**Start.** The server loads every compiled kernel the engine ships (`src/wdb_preload.py`) and opens the
database before it answers `./check` -- program code only; nothing from the data, and no result, is cached
across the restart. Between hot runs the engine keeps decoded source data (dictionaries, codes) in memory, like
a buffer pool; no query result or intermediate result is kept.

**Queries.** `queries.sql` is the standard set, one statement per line in canonical order; `length()` counts
characters.
