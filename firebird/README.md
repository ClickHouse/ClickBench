# Firebird

[Firebird](https://firebirdsql.org/) 5.0, a row-oriented relational database, installed from the official release tarball (Ubuntu packages only Firebird 3.0) and running in the default SuperServer mode.

## Schema

String columns are `VARCHAR(n) CHARACTER SET NONE`, which stores raw bytes: the dataset contains invalid UTF-8, and `CHAR_LENGTH` then counts bytes, like `length` in other systems.

The widths are only slightly above the longest value of each column in the dataset (e.g. 7770 bytes in `URL`, 8134 in `OriginalURL`), for two reasons:

- Firebird limits the declared size of a row to 64 KB. With a UTF-8 character set every character counts as four bytes, and the table does not fit.
- `GROUP BY` and `ORDER BY` are done by sorting fixed-width records, where a `VARCHAR` key takes its declared length. Grouping by a `VARCHAR(8192)` column writes 8 KB per row to the sort, whatever the actual length of the values.

The primary key is `(CounterID, EventDate, UserID, EventTime, WatchID)`, as for MySQL and SQLite. It is created after the load, so that the index is built with parallel workers.

## Loading

Firebird has no `COPY`-like statement, and external tables require fixed-width records. `loader.cpp` parses `hits.tsv` and inserts rows using the batch API (`IBatch`) of Firebird 4+, attached in embedded mode, with four threads (more threads were slower, due to contention inside the engine). Forced writes are disabled during the load and enabled again afterwards.

## Queries

The PostgreSQL queries with these changes:

- `LIMIT n OFFSET m` becomes `OFFSET m ROWS FETCH NEXT n ROWS ONLY`, and `length` becomes `CHAR_LENGTH`.
- Firebird has no `REGEXP_REPLACE`. Q29 uses `SUBSTRING ... SIMILAR` instead: two patterns, with and without `www.`, are combined with `COALESCE`, since the part of a `SIMILAR` pattern before the captured group is matched non-greedily.
- Firebird has no `DATE_TRUNC`. Q43 truncates to minutes with `DATEADD`/`DATEDIFF`.
- `GROUP BY` on a select-list alias is not supported, so Q29, Q40, Q43 group by position.

## Expected limitations

- Every query runs in a single thread: Firebird 5 uses parallel workers only for index creation, sweep, backup and restore.
- Aggregation is always done by sorting. Q34 and Q35 group 100 million rows by `URL`, which needs about 800 GB of temporary space with 8 KB sort keys, more than the disk of the benchmark machine, so they fail.
- The official ARM64 binaries of Firebird 5.0.4 are compiled with `-p` (profiling instrumentation calling `_mcount` in every function), which costs around 40% of CPU time in the load. The flag was removed on `master` in commit [5231e27](https://github.com/FirebirdSQL/firebird/commit/5231e27746), but not in the `v5.0-release` branch. The x86-64 binaries are not affected.
