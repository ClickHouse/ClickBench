# YDB

A single-node [YDB](https://ydb.tech) server from the binaries of the latest
stable release (resolved from GitHub releases, the release candidates are
skipped), with the latest stable YDB CLI.

- Deployment: the single-node configuration of the local deployment scripts of
  https://install.ydb.tech (`config/disk.yaml`): a storage node with one PDisk
  in a preallocated file, and a database node for the database
  `/Root/bluesky`. The only change is the automatic actor system configuration
  (`use_auto_config`) for the number of CPUs of the machine instead of the
  small fixed thread pools of the sample, which is how YDB is deployed on a
  server.
- Table: a column-oriented table (`STORE = COLUMN`) with a `JsonDocument`
  column (see `ddl.sql`). A column table needs a primary key of non-JSON
  columns: it is the position of the document in the dataset, (file, line).
  Nothing is extracted from the documents.
- Loading: every file is converted to CSV (`to-csv.py`, which drops the few
  invalid lines of the dataset and removes `\u0000`, as for PostgreSQL) and
  imported with `ydb import file csv` (BulkUpsert) with the default settings.
- Queries: YQL with `JSON_VALUE`; Q2 uses the exact `COUNT(DISTINCT ...)`.
  The runtime is the server-side `total_duration_us` of the query statistics,
  as in the main ClickBench YDB entry.
- Data size: the compressed size of the active portions of the column table
  (`.sys/primary_index_portion_stats`); the PDisk file is preallocated.
- Q3 filters the collections with `OR` of equalities instead of `IN`: with
  `IN (...)` over `JSON_VALUE` (also in `HAVING` or in a subquery), the column
  shard fails a `VERIFY` (`i.GetColumnId() != resourceId`, `abstract.h:394`)
  and the database node goes down; the `OR` form is equivalent.
