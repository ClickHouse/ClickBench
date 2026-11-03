# MySQL

The latest GA release of MySQL (the "innovation" track of the official APT repository), with the default settings, except `local_infile = 1`, which `LOAD DATA LOCAL INFILE` requires.

- The documents are stored in one `JSON` column of an InnoDB table.
- A functional index covers the fields that the queries filter and group by, as the expression index of [`../postgresql`](../postgresql). Its key parts are `CAST(data ->> '$.field' AS CHAR(n)) COLLATE utf8mb4_bin`, so that the optimizer matches them with the `data ->> '$.field'` expressions of the queries. It is created after the load.
- `./load` runs one `LOAD DATA LOCAL INFILE` per file from the decompressed stream, with a field terminator that never occurs in the data and no escape character, so every line becomes one JSON value. The few lines that are not valid JSON (documents longer than 64 KiB that were split over two lines) are dropped by `./filter.py` before the load. The binary log is turned off for the loading session (as in the main ClickBench): it would store a second copy of the data.
- The queries use `->>` and compute the timestamps as `TIMESTAMPADD(MICROSECOND, time_us, TIMESTAMP '1970-01-01 00:00:00')`, which keeps the microseconds and does not depend on the time zone. Q2 counts the distinct users exactly.
- The InnoDB buffer pool has its default size, 128 MiB, so the hot runs read the data from the disk.
