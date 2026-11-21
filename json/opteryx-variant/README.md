# Opteryx (VARIANT)

The same engine and server as [`../opteryx`](../opteryx) (opteryx-core from PyPI, embedded, a long-lived query server restarted before every cold run), but the documents are loaded into a table instead of being read from the NDJSON files on every query.

Loading (`load`, `load.py`): every line is read whole into one column, `data`, of the `VARIANT` type (`READ_JSONL(..., as_variant => 'data', ignore_errors => true)`; the few records that are not valid JSON are skipped, as in `../opteryx`), and written as Parquet by rugo, the Parquet writer bundled in opteryx-core.
A `VARIANT` column is written as a shredded Parquet `VARIANT` (the Parquet specification's Variant shredding): the paths the documents have in common are stored as typed columns inside the `data` group, and everything else stays in the Variant binary; the documents are not flattened into separate columns.
Each file is sorted by the five paths the queries read (`kind`, `commit.operation`, `commit.collection`, `did`, `time_us`), as [`../clickhouse`](../clickhouse) sorts its table.

Queries: paths are read with `->` / `->>` (`data->'commit'->>'collection'`) and cast where a number is needed (`CAST(data->>'time_us' AS INT64)`); the results have the same types as `../opteryx`. A query reads only the shredded paths it needs, and a filter on a path skips the row groups whose statistics rule it out.

`retains_structure` is `yes`: the documents keep their nested objects and arrays and can be read back whole (`SELECT data`).
The conversion from JSON is lossy in corner cases: object members come back with the shredded ones first (key order is not kept), a key repeated in one object keeps its first value, integers that do not fit into 64 bits are stored as doubles, and numbers are normalized (`1e2` becomes `100.0`).
