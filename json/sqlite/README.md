# SQLite

The latest SQLite (the precompiled command-line shell from https://sqlite.org/download.html), embedded, with the default settings.

The documents are stored as `JSONB`, the binary JSON format of SQLite 3.45+, in a `BLOB` column (`jsonb(line)` on load), and the queries extract the paths with the `->>` operator.

Loading: one transaction per file; the shell's `.import` reads the decompressed file in the `ascii` mode (no quoting) with the newlines translated to the record separator, into a temporary staging table, and the lines are converted with `jsonb`.
The few lines of the dataset that are not valid JSON objects (documents longer than 64 KiB that were cut into two lines) are skipped with `json_valid`.

As in [`../postgresql`](../postgresql), there is one index over the expressions used in the filters and the aggregations (`kind`, `commit.operation`, `commit.collection`, `did`, `time_us`). It is created after the load (included in the load time), followed by `ANALYZE`. Queries 2-5 use the index; query 1 has no filter and scans the table.

Queries 3-5 extract the paths in a derived table with `LIMIT -1` (no limit), and aggregate in the outer query.
This is the same query, but the `LIMIT` keeps SQLite from flattening the derived table into the aggregation, so that all the values come from the index.
Otherwise SQLite keeps the `data` column of the table as a "bare column" of the aggregation and reads the table row (a random read) for every row of query 3 (it groups through a sorter) and for every new `min`/`max` value in queries 4 and 5: at 1m, the cold runs took 20-42 s instead of 0.5-3 s, and with the table larger than the memory the hot runs would do the same random reads.

SQLite executes a query in a single thread.
