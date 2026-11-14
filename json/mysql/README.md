# MySQL

The latest GA release of MySQL (the "innovation" track of the official APT repository), with the default settings, except `local_infile = 1`, which `LOAD DATA LOCAL INFILE` requires.

- The documents are stored in one `JSON` column of an InnoDB table.
- There is no index, see below.
- `./load` runs one `LOAD DATA LOCAL INFILE` per file from the decompressed stream, with a field terminator that never occurs in the data and no escape character, so every line becomes one JSON value. The few lines that are not valid JSON (documents longer than 64 KiB that were split over two lines) are dropped by `../lib/filter-documents.py` before the load, and so are the documents nested deeper than 100 levels, the limit of MySQL's JSON (file 178 has four, nested 2163 levels deep). The load is permissive: a file that fails anyway is skipped, and the loaded documents are reported as the data quality. The binary log is turned off for the loading session (as in the main ClickBench): it would store a second copy of the data.
- The queries use `->>` and compute the timestamps as `TIMESTAMPADD(MICROSECOND, time_us, TIMESTAMP '1970-01-01 00:00:00')`, which keeps the microseconds and does not depend on the time zone. Q2 counts the distinct users exactly.
- The InnoDB buffer pool has its default size, 128 MiB, so the hot runs read the data from the disk.

## Why there is no index

The first version had a functional index on the fields that the queries filter and group by, like the expression index of [`../postgresql`](../postgresql): `(CAST(data ->> '$.kind' AS CHAR(32)) COLLATE utf8mb4_bin, ..., CAST(data ->> '$.did' AS CHAR(320)) COLLATE utf8mb4_bin, CAST(data ->> '$.time_us' AS UNSIGNED))`, built after the load. The optimizer used it for the conditions on `kind`, `commit.operation` and `commit.collection`, which match most of the rows, and then looked up every matching row in the table. With the default buffer pool, every lookup is a random read from the disk, so on 1m documents Q2 took 423 s and Q4/Q5 37 s, against 3.5 s for the full scan of Q1. Without the index, all queries are full scans.
