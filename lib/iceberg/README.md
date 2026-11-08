# Iceberg entries

The entries in the `*-iceberg` directories benchmark systems that can write
Apache Iceberg tables. Instead of reading the benchmark-provided Parquet files
in place (the `parquet` and `datalake` storage kinds), each system creates an
Iceberg table itself, writes the dataset into it, and runs the queries over the
table it has written. The result shows how good a system is both as a writer
and as a reader of Iceberg: the layout of the data files, their sizes, the
encodings, compression and statistics that the system chooses by default all
matter for the queries.

On the website, these entries have the storage kind `Iceberg`.

## Rules

1. The system creates the table `clickbench.hits` through the Iceberg REST
   catalog, with the column types of [`hits.schema.json`](hits.schema.json)
   (`long`, `int`, `string`, `timestamp`, `date`), unpartitioned and unsorted,
   with the default table properties.
2. If the system can write into an existing Iceberg table but cannot create
   one, the table is created by `lib/iceberg/catalog create-table`, which asks
   the catalog to write the initial metadata of the table with the same schema.
   This is the only emulation allowed.
3. The system writes the dataset with a single `INSERT ... SELECT` (or its
   equivalent) from the downloaded Parquet files, `hits_{0..99}.parquet`, with
   the default settings. Settings that only enable a feature (for example,
   `allow_insert_into_iceberg` in ClickHouse) are fine; settings that change how
   the data is written (file sizes, row group sizes, compression, sort order,
   distribution, the number of writers) are not. The conversion of the columns
   from the raw types of the Parquet files (Unix time in seconds, days since
   epoch, binary strings) is a part of the `SELECT`.
4. No explicit optimization or maintenance: no compaction, `OPTIMIZE`,
   `rewrite_data_files`, snapshot expiration, sorting or clustering after the
   load, unless the system does it automatically and on its own.
5. The load time is the wall-clock time of the creation and the write,
   including the commit to the catalog.
6. The data size is the total size of all objects of the table in the storage:
   data files, manifests, manifest lists, and metadata files.
7. The queries run over the table through the catalog, as usual. Each cold run
   restarts the system and drops its caches, including any local cache of the
   remote objects; the storage itself is not restarted.

## Storage and catalog

The scripts here hide the storage from the entries. An entry sources
`lib/iceberg/env.sh` and refers only to its variables:

| Variable | Meaning |
|---|---|
| `LAKE_S3_ENDPOINT`, `LAKE_S3_ENDPOINT_HOST`, `LAKE_S3_USE_SSL`, `LAKE_S3_PATH_STYLE` | the S3 API |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` | the credentials for S3 |
| `LAKE_CATALOG_URI`, `LAKE_WAREHOUSE`, `LAKE_WAREHOUSE_LOCATION` | the Iceberg REST catalog |
| `LAKE_OAUTH_URI`, `LAKE_CLIENT_ID`, `LAKE_CLIENT_SECRET` | OAuth2 client credentials for the catalog |
| `LAKE_NAMESPACE`, `LAKE_TABLE` | `clickbench`, `hits` |

The prefix is `LAKE_` rather than `ICEBERG_`, because programs read variables
like `ICEBERG_WAREHOUSE` themselves (SeaweedFS does).

The scripts, run from the entry directory:

- `install` installs the storage;
- `start` starts the storage and the catalog, if they are not running, and
  creates the `clickbench` namespace; the `start` of every entry calls it;
- `data-size` prints the size of the table in the storage;
- `catalog` is a minimal REST catalog client: `create-namespace`,
  `create-table`, `drop-table`, `load-table`;
- `substitute` fills `{LAKE_...}` placeholders in the configuration files of
  the engines.

### SeaweedFS (the current version)

The storage is [SeaweedFS](https://github.com/seaweedfs/seaweedfs) running as
`weed mini` on localhost: a single process with an S3 API (port 8333) and a
built-in Iceberg REST catalog (port 8181) over "table buckets", an
implementation of the AWS S3 Tables API. The warehouse is the table bucket
`warehouse`; the catalog authenticates with OAuth2 client credentials, which
are the S3 keys, and also supports SigV4.

`weed mini` runs background maintenance workers. Those that work on the
volumes (vacuum, erasure coding, balance) do not touch the content of the
objects. The Iceberg table maintenance job (compaction, snapshot expiration,
orphan file removal) is disabled by default, and the entries never enable it.

One deviation from a plain object store: when a commit adds a snapshot whose
manifest list lacks field ids or uses relative paths, the catalog writes
repaired copies of the manifest list and manifests. Only the metadata is
rewritten, never the data files.

### A real S3 bucket (the planned version)

The final version writes into a real S3 bucket with a role that the benchmark
machine assumes, every run in its own temporary prefix, which is deleted after
the run. The catalog then has to be one that can place a warehouse in an
arbitrary prefix of a general-purpose bucket, such as AWS Glue (through its
Iceberg REST endpoint) or a self-hosted REST catalog running on the benchmark
machine. It is a new `LAKE_STORAGE` mode in `env.sh` plus the matching
branches in `install`, `start` and `data-size`; the entries stay as they are.
The managed services that write Iceberg into a customer bucket (see below)
become possible to add at that point.

## Systems

Implemented:

| Entry | Writer | Catalog access |
|---|---|---|
| `clickhouse-iceberg` | ClickHouse, `DataLakeCatalog` database, `CREATE TABLE` + `INSERT` | REST, OAuth2 |
| `duckdb-iceberg` | DuckDB `iceberg` extension, `ATTACH ... (TYPE ICEBERG)`, `CREATE TABLE` + `INSERT` | REST, OAuth2 |
| `spark-iceberg` | Spark 4.1 with the Iceberg runtime 1.12, `CREATE TABLE ... USING iceberg` + `INSERT` | REST, OAuth2 |
| `trino-iceberg` | Trino Iceberg connector, `CREATE TABLE` + `INSERT` | REST, OAuth2 |
| `starrocks-iceberg` | StarRocks external Iceberg catalog, `CREATE TABLE` + `INSERT ... FROM FILES()` | REST, OAuth2 |
| `doris-iceberg` | Doris 4.1 Iceberg catalog, `CREATE TABLE` + `INSERT ... FROM local()` | REST, OAuth2 |
| `presto-iceberg` | Presto 0.300 Iceberg connector, `CREATE TABLE` + `INSERT` | REST, OAuth2 |
| `databend-iceberg` | Databend nightly Iceberg catalog, `CREATE TABLE ... ENGINE = ICEBERG` + `INSERT` (column names are lowercase, as Databend folds unquoted identifiers) | REST, OAuth2 |
| `datafusion-iceberg` | DataFusion through the DataFusion integration of iceberg-rust 0.11, `CREATE TABLE` + `INSERT` (a small binary, `src/main.rs`) | REST, OAuth2 |

Can be added on top of the same storage:

- Dremio: Iceberg REST catalog sources with `CREATE TABLE AS`.
- Daft and Polars: `write_iceberg` through PyIceberg, which also creates the
  table; queries with their own SQL over `read_iceberg`/`scan_iceberg`.
- Sail: Iceberg reads and writes in its Spark-compatible API.
- chDB: the same engine as ClickHouse, embedded.
- Apache Flink (batch SQL) and RisingWave: both write Iceberg through a REST
  catalog, but are streaming systems first.
- Impala and Hive write Iceberg only through a Hive Metastore catalog.

Need the real S3 bucket, being managed services: Snowflake (Iceberg tables on
an external volume), Databricks, Amazon Athena and Redshift (Iceberg tables in
Glue), Amazon EMR, Starburst Galaxy, Dremio Cloud, ClickHouse Cloud,
MotherDuck.

Firebolt writes Iceberg only with `CREATE ICEBERG TABLE ... AS SELECT` into a
file-based catalog (the table metadata in the bucket, no catalog service) on
AWS S3, with no option for another S3 endpoint, so it needs the real S3
bucket and a rule that allows the file-based catalog.

## Local testing

Each entry runs its own `weed` in its directory (`seaweedfs-data`,
`seaweedfs.log`) on fixed ports, so only one Iceberg entry can run on a
machine at a time. To start from scratch, stop the entry, kill `weed`, and
remove `seaweedfs-data`.
