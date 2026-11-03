# SQLite

The latest SQLite (the precompiled command-line shell from https://sqlite.org/download.html), embedded, with the default settings.

The documents are stored as `JSONB`, the binary JSON format of SQLite 3.45+, in a `BLOB` column (`jsonb(line)` on load), and the queries extract the paths with the `->>` operator.

Loading: one transaction per file; the shell's `.import` reads the decompressed file in the `ascii` mode (no quoting) with the newlines translated to the record separator, into a temporary staging table, and the lines are converted with `jsonb`.
The few lines of the dataset that are not valid JSON objects (documents longer than 64 KiB that were cut into two lines) are skipped with `json_valid`.

As in [`../postgresql`](../postgresql), there is one index over the expressions used in the filters and the aggregations (`kind`, `commit.operation`, `commit.collection`, `did`, `time_us`). It is created after the load (included in the load time), followed by `ANALYZE`. Queries 2-5 use the index; query 1 has no filter and scans the table.

SQLite executes a query in a single thread.
