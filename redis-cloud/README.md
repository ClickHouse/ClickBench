# Redis Cloud Pro (Trino)

ClickBench's 43 SQL queries run through the Redis SQL Trino connector. Data lives
in Redis Cloud Pro all-RAM hashes with a Redis Query Engine index. Trino evaluates
SQL operations the connector cannot push into Redis. This measures the combined
Redis + Trino deployment, including receiving all query result pages at the client.

## Setup

Use Ubuntu 24.04 on a dedicated AWS runner in the Redis subscription's VPC, region
and availability zone. Use AZ IDs to verify physical placement when accounts differ.
The configuration below uses a single-AZ, non-replicated database for benchmarking.
It does not provision Flex. Flex v2 is outside this entry until tested separately.

The initial test deployment uses:

- AWS us-east-1a / use1-az6; same AWS account and VPC for client and server.
- Redis Cloud Pro 8.6, 1,000 GB dataset capacity, 40 shards, RESP3, OSS Cluster API
  enabled, default query performance factor, `noeviction`, AOF every second.
- Redis hosts: three r8g.16xlarge instances. Each data disk is gp3, 1,598 GB,
  16,000 IOPS, 1,000 MiB/s. Root volumes retain their defaults.
- Trino client: r7a.4xlarge (16 vCPUs, 128 GiB RAM); 500 GB gp3 disk, 16,000 IOPS,
  1,000 MiB/s. Trino JVM: 96 GiB heap, 64 GB per-query memory, 24 GB heap headroom.
- Trino 483 and the exact connector revision in `versions.env`.

These are provisioning settings, not measured results. Record actual versions,
capacity, shard count, worker settings, billing and disk settings with every run.
A 10,000-row real-data sample used about 75 MB including hashes and indexes;
monitor the full load because high-cardinality index growth is not necessarily linear.

Install the connector and loader:

```sh
./install
```

Create a private JSON connection file outside the checkout, mode 0600:

```json
{"host":"PRIVATE_REDIS_HOST","port":14756,"password":"DATABASE_PASSWORD"}
```

Use `"ssl": true` when connecting with TLS; the server certificate must validate.
The Cloud API account/user keys are provisioning credentials and are not needed
by the benchmark runner. Never put any credentials in results or committed files.
The default and OSS Cluster API paths use the same private endpoint, database,
credentials, data and Trino settings; the database's `supportOSSClusterApi` flag and `redisearch.cluster` change together.

```sh
export REDIS_CONNECTION_FILE=/secure/path/redis-connection.json
export PLUGIN_DIR="$PWD/plugin"
./start-cloud
curl --fail --location --output ../hits.parquet \
  https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet
./load-cloud | tee load.log
RESULT_DIR=cloud-results-default ./run.sh --mode default | tee default-run.log
# Enable supportOSSClusterApi on the Cloud database; wait until active.
RESULT_DIR=cloud-results-cluster ./run.sh --mode cluster | tee cluster-run.log
```

Wait for Trino `/v1/info` to report `starting: false` before loading. The dataset
must be completely downloaded before the load timer starts. Loading includes
indexing and verifies exactly 99,997,497 source rows and indexed documents.
Hash keys use physical row ordinals, because WatchID is not unique. Numeric IDs
are written as decimal integers without conversion to doubles. Dates are ISO dates;
Parquet timestamp seconds become epoch milliseconds, as the connector requires.
All 105 columns are created with the connector's standard schema; no extra
materialized views, preaggregations, or manually tuned indexes are used.

`load-cloud` requires an empty dedicated database. It never flushes a database.
For another run, create a fresh database or explicitly remove only the benchmark
data. `load.py --limit` exists for smoke tests; never submit subset timings.

## API comparison and result reporting

`run-cloud.py` runs three tries per query in the selected mode. Run the default
API phase with Cloud OSS Cluster API disabled, then enable it for the cluster
phase. Changing only the client flag while OSS Cluster API is enabled produces
MOVED errors for ordinary clients. Preserve the same data and hardware across
phases; record their order, and repeat in reverse order if comparing cache effects. It restarts Trino and clears the runner's page cache
before each mode/query block. Redis Cloud remains running. Thus **both result files
must have the `no-cold` tag**: the first try is not a true cold Redis measurement.
There is no query-result cache. Each query consumes and writes all returned results.
Failed queries have `null` timings, with errors retained in `samples.jsonl`.

The selected `RESULT_DIR` contains the three timings per query, result CSVs, errors, and
checksums. Retain these as raw evidence. Compare successful query outputs between
modes, accounting for unspecified order and ties at a LIMIT boundary, before
publishing timings. Include correctness failures as `null`, not fast successful
numbers. Check representative numeric aggregates against a reference engine.

The connector revision includes a correctness fix for grouping NUMERIC BIGINTs:
Redis's double-based grouping can merge adjacent IDs beyond 2^53. Those groups are
computed by Trino from the exact hash values. See redis-sql-trino PR #125.

After a full verified run, add two JSON files under `results/YYYYMMDD/`, labeled
`Redis Cloud (Trino)` and `Redis Cloud (Trino, OSS Cluster API)`. Include all 43
three-value arrays, load time, actual data size, machine metadata, and `no-cold`.
For data size include hash/index memory and persistent log bytes where available;
do not substitute provisioned capacity or the Parquet source size. Do not create
result files until the full run and correctness checks finish.

Stop and remove the task's Trino container and delete the dedicated Redis Cloud
subscription and runner after downloading results. Deleting the subscription's
managed VPC also requires terminating the runner and deleting its security group
first. Retain source/results; discard private credential files and task SSH keys.
