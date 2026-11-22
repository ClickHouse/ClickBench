# Opteryx (Iceberg)

Opteryx writing and reading an Apache Iceberg table through the Iceberg REST
catalog of `lib/iceberg` (see `lib/iceberg/README.md` for the rules).

- `./load` creates `clickbench.hits` with `create.sql` (the column types of
  `lib/iceberg/hits.schema.json`; Opteryx's `INTEGER` is 64-bit, so Iceberg
  `int` is `INT32`) and writes the dataset with the single
  `INSERT ... SELECT` of `insert.sql`, default settings. The conversion from
  the raw Parquet types (Unix seconds, days since epoch, binary strings,
  narrow integers) is in that `SELECT`.
- Every file of the table is written by Opteryx's own file engine (rugo):
  Parquet data files with the Iceberg field-ids in their schema, and the Avro
  manifests and manifest lists. PyIceberg is used only as the REST catalog
  client, through `opteryx-iceberg`.
- The table is format-version 2, unpartitioned, unsorted, with default
  properties. An `INSERT` is one fast-append snapshot.
- Queries run on a long-lived server (`server.py`, as in `../opteryx`),
  restarted for every cold try. The storage is not restarted. Opteryx's
  on-disk caches are off by default, so a restarted server holds nothing.
- `queries.sql` is `../opteryx/queries.sql` against `lake.clickbench.hits`,
  without the raw-type casts that entry needs (`EventTime`, `EventDate` and
  the string columns are typed in the table).
