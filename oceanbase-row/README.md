This is the `oceanbase` entry with one change: `hits` is created
`WITH COLUMN GROUP (all columns)` instead of `(each column)`, so it stays in
OceanBase's row store — the LSM-tree layout every table had before 4.3
introduced the columnstore engine, and still what a plain `CREATE TABLE` gives
you.

Read `../oceanbase/README.md` first: the RPM unpacking, the bootstrap that has
to happen inside `./install`, the resource unit sized from `GV$OB_SERVERS`, the
`olap` parameter template, the `VARCHAR` widths and the 1.5 MB row limit, the
direct load and the `secure_file_priv` Unix-socket rule are all identical here
and are only described there.

To run the benchmark:

```
./benchmark.sh
```

## What differs from the columnstore entry

- `create.sql` says `WITH COLUMN GROUP (all columns)` — one group holding every
  column, which is what a row is. `SHOW CREATE TABLE` is otherwise identical to
  the columnstore entry's, down to `COMPRESSION = 'zstd_1.3.8'`,
  `SKIP_INDEX_LEVEL = 1`, `DELTA_FORMAT = 'encoding'`,
  `MERGE_ENGINE = DELETE_INSERT` and `COLLATE = utf8mb4_bin`; the table is
  still sorted by `(CounterID, EventDate, UserID, EventTime, WatchID)`. Only
  the physical grouping of the columns changes.

  Spelling the group out matters: with the `olap` template's
  `default_table_store_format = 'column'` in force, simply *omitting* the
  clause produces a columnstore table, not a rowstore one.
- `install` sets `default_table_store_format = 'row'` rather than `'column'`,
  so the parameter and the schema say the same thing.

Everything else — the same 43 queries, the same load path, the same instance
and tenant sizing — is byte-for-byte the columnstore entry, so the difference
between the two result sets is the storage format and nothing else.

## Verification

Validated at 1% scale on the same instance as the columnstore entry: the DDL
produces `WITH COLUMN GROUP(all columns)` with every other table option
identical, the load gets all rows in, and all 43 queries return a result. The
comparison against `clickhouse-local` lands in the same place as the
columnstore entry's — 32 of 43 identical, the rest `LIMIT` ties plus the two
semantic differences (`AVG(UserID)` overflowing in ClickHouse, and
`utf8mb4_bin` being a `PAD SPACE` collation) that `../oceanbase/README.md`
describes.

The 100-million-row load has only been run for the columnstore entry. No
results yet — those need runs on the benchmark's own EC2 machines.
