# SlothDB (Parquet, single)

Stateless variant of [`slothdb/`](../slothdb): the dataset is *not* ingested
into a SlothDB table. Instead, `create.sql` defines a `VIEW` over
`hits.parquet` via `read_parquet(...)` and queries scan the parquet file
directly at query time. The view is persisted in `hits.slothdb` so each
`./query` invocation sees it without re-creating it.

`./data-size` reports the on-disk size of `hits.parquet` (the only source
of truth in this configuration).

The view normalises `EventDate` and the `*Time` columns into proper
`DATE` / `TIMESTAMP` values, so `queries.sql` is the same one used by
`slothdb/` — no `toDateTime`-style macro is required.
