# ParadeDB

[ParadeDB](https://www.paradedb.com/) is PostgreSQL with the `pg_search` extension. `./install` sets it up the way the ParadeDB documentation describes for a self-managed server: the latest PostgreSQL from the PGDG repository, `pgvector` (a dependency of `pg_search`), the `pg_search` package of the latest ParadeDB release from GitHub, and `shared_preload_libraries = 'pg_search'`. Everything else is the default configuration.

The table, the load and the queries are the same as in [`../postgresql`](../postgresql): one `JSONB` column (`lz4` TOAST compression), a B-tree expression index on the fields that the queries filter and group by, one `COPY ... ON_ERROR ignore` per file (it skips the few lines of the dataset that are not valid JSON), and the five queries in plain SQL.

## Why there is no ParadeDB (BM25) index

ParadeDB's own index type (`CREATE INDEX ... USING paradedb (id, data)`, formerly `USING bm25`) indexes all sub-fields of a `JSONB` column, and ParadeDB can compute aggregates from the columnar part of that index. It is not used here, because it would not accelerate the JSONBench queries as they are written:

- ParadeDB pushes an aggregate down to its index only when the query contains a ParadeDB search predicate (e.g. `id @@@ pdb.all()`); the JSONBench queries are plain SQL with ordinary comparisons, so they would need to be rewritten.
- Even then, grouping by a scalar function (`EXTRACT(HOUR FROM TO_TIMESTAMP(...))` in Q3) and aggregates over expressions (`MIN`/`MAX` of a timestamp computed from `time_us` in Q4 and Q5) fall back to the PostgreSQL executor.

So the index would only add to the load time and the data size, while the queries would run exactly as in PostgreSQL. This entry therefore measures the PostgreSQL that ParadeDB ships with, with `pg_search` loaded; its results are expected to be close to the PostgreSQL entry.
