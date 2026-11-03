# MariaDB

The latest stable MariaDB from the official MariaDB repository (the default of its `mariadb_repo_setup` script), with the default settings.

- MariaDB has no binary JSON type: its `JSON` is an alias of `LONGTEXT` with a `JSON_VALID` check constraint. The table has one such column, spelled out (`LONGTEXT ... CHECK (JSON_VALID(data))`) to give it the binary collation, so that the strings extracted from the documents compare and group exactly.
- The fields that the queries filter and group by are indexed, as with the expression index of [`../postgresql`](../postgresql): MariaDB has no functional indexes, so these are virtual (not stored) generated columns with an index on them, added after the load. The queries do not refer to the generated columns: they use `JSON_VALUE` on the document, which the optimizer may match with the indexed columns.
- `./load` runs one `LOAD DATA LOCAL INFILE` per file from the decompressed stream, with a field terminator that never occurs in the data and no escape character, so every line becomes one document. The few lines that are not valid JSON (documents longer than 64 KiB that were split over two lines) are dropped by `./filter.py` before the load.
- The queries use `JSON_VALUE` and compute the timestamps as `TIMESTAMPADD(MICROSECOND, time_us, TIMESTAMP '1970-01-01 00:00:00')`, which keeps the microseconds and does not depend on the time zone. Q2 counts the distinct users exactly.
- The InnoDB buffer pool has its default size, 128 MiB, so the hot runs read the data from the disk.
