# BemiDB

[BemiDB](https://github.com/BemiHQ/BemiDB) is a Postgres read replica optimized
for analytics. It is a single Go binary that embeds the [DuckDB](https://duckdb.org/)
query engine, stores data in the [Apache Iceberg](https://iceberg.apache.org/)
table format (compressed Parquet), and speaks the PostgreSQL wire protocol so
existing Postgres clients and tools can query it.

This benchmark pins **v0.51.1**, the last release of the self-contained,
single-binary, local-storage line. The later v1.x releases pivoted to a
multi-container product that mandates S3 object storage and a separate catalog
database, which does not fit ClickBench's single-VM, reproducible model.

## How the data is loaded

BemiDB has no bulk-import command of its own — its only ingestion path is
syncing tables from a source PostgreSQL database. Loading the ClickBench
dataset is therefore a two-step pipeline (see `load`):

1. Bulk-load `hits.tsv` into a staging PostgreSQL database (`COPY ... FREEZE`).
2. Run `bemidb sync`, which reads the table over a serializable read-only
   snapshot and rewrites it as Iceberg/Parquet in the local `./iceberg`
   directory.

Both steps are included in the reported **load time**, because together they
are what it takes to get the dataset queryable in BemiDB. After the sync, the
staging PostgreSQL is stopped so it does not hold RAM during the query phase —
only BemiDB is resident, serving queries from its own Iceberg storage.

The reported **data size** is the size of the `./iceberg` directory (Parquet
data files plus Iceberg metadata). The staging PostgreSQL is torn down and not
counted.

## Notes

- No Docker is required: the BemiDB binary is downloaded from GitHub Releases
  (`amd64`/`arm64` auto-detected) and PostgreSQL is installed from the PGDG apt
  repository.
- Each query is run through the shared driver's cold/warm cycle. BemiDB is a
  daemon that reads Parquet from the local disk, so the cold run is genuinely
  cold after `drop_caches` (hence the `lukewarm-cold-run` tag, matching the
  other DuckDB-backed, on-disk systems).
- Queries and the table schema are the standard PostgreSQL-compatible ClickBench
  files, unchanged. Any query the engine cannot execute is recorded as `null`.
