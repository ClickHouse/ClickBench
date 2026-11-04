# MariaDB

The latest stable MariaDB from the official MariaDB repository (the default of its `mariadb_repo_setup` script), with the default settings.

- MariaDB has no binary JSON type: its `JSON` is an alias of `LONGTEXT` with a `JSON_VALID` check constraint. The table has one such column, spelled out (`LONGTEXT ... CHECK (JSON_VALID(data))`) to give it the binary collation, so that the strings extracted from the documents compare and group exactly.
- There is no index, see below.
- `./load` runs one `LOAD DATA LOCAL INFILE` per file from the decompressed stream, with a field terminator that never occurs in the data and no escape character, so every line becomes one document. The few lines that are not valid JSON (documents longer than 64 KiB that were split over two lines) are dropped by `../lib/filter-documents.py` before the load, and so are the documents nested deeper than 32 levels, the limit of MariaDB's JSON functions, which the `JSON_VALID` check would reject (file 178 has four, nested 2163 levels deep). The load is permissive: a file that fails anyway is skipped, and the loaded documents are reported as the data quality.
- The queries use `JSON_VALUE` and compute the timestamps as `TIMESTAMPADD(MICROSECOND, time_us, TIMESTAMP '1970-01-01 00:00:00')`, which keeps the microseconds and does not depend on the time zone. Q2 counts the distinct users exactly.
- The InnoDB buffer pool has its default size, 128 MiB, so the hot runs read the data from the disk.

## Why there is no index

The first version had an index on virtual generated columns for the fields that the queries filter and group by (`kind`, `commit.operation`, `commit.collection`, `did`, `time_us`), the counterpart of the expression index of [`../postgresql`](../postgresql), added after the load. The optimizer used it for the conditions, which match most of the rows, and then looked up every matching row in the table. With the default buffer pool, every lookup is a random read from the disk, so on 1m documents Q2 took 71 s and Q4/Q5 39 s, against 2-3 s for the full scan of Q1. Without the index, all queries are full scans.
