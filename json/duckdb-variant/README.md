# DuckDB (VARIANT)

The same setup as [`../duckdb`](../duckdb) (the latest DuckDB, embedded, the CLI), but the documents are stored in a column of the `VARIANT` type (DuckDB 1.5+) instead of `JSON`.
See https://github.com/ClickHouse/JSONBench/issues/130.

Loading: `read_ndjson_objects(...)` with `ignore_errors = true` (the few broken lines of the dataset become NULLs and are skipped), and the `JSON` values are cast with `json::VARIANT`.
At the checkpoint, DuckDB shreds the common structure of the `VARIANT` values into typed columns, and the queries read only the shredded paths they need.

Queries: paths are accessed with the dot notation (`data.commit.collection`), which returns a `VARIANT`, and cast to `VARCHAR`/`BIGINT` (`data.time_us::BIGINT`). Q2 uses the exact `count(DISTINCT ...)`.

`retains_structure` is `yes`: `VARIANT` keeps the nested objects and arrays and the order of the keys.
The conversion from JSON is lossy in corner cases that the dataset does not have: duplicate keys keep only the last value (as in PostgreSQL's `JSONB`), integers that don't fit into 64 bits become strings, and numbers are normalized (`1.5e10` becomes `15000000000.0`).
For the first file of the dataset (1,000,000 documents), `CAST(CAST(json AS VARIANT) AS JSON)` gives back documents equal to the originals, with the same key order.
