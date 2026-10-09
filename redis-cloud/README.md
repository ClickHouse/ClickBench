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
- Trino client: r7a.4xlarge (16 vCPUs, 128 GiB RAM); 500 GB gp3 data disk, 16,000 IOPS,
  1,000 MiB/s, plus a 20 GB gp3 boot disk with default 3,000 IOPS / 125 MiB/s. Trino JVM: 96 GiB heap, 64 GB per-query memory, 24 GB heap headroom.
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

For a database already using OSS Cluster API, load with `BENCHMARK_MODE=cluster`.
The default `LOAD_WORKERS=8` can load independent Parquet row groups in parallel; each
row retains its original physical ordinal, and all worker errors abort the run.

Redis query timeouts must fail explicitly (`CONFIG SET search-on-timeout fail`)
so partial results are not treated as valid. Preserve this setting with the run metadata.

`load-cloud` requires an empty dedicated database. It never flushes a database.
For another run, create a fresh database or explicitly remove only the benchmark
data. An interrupted parallel load of the identical source file can use
`load.py --workers 8 --resume`; completed row groups are reused, partial groups
are rewritten by the same physical ordinals, and the final global index count
is still required. Do not publish resumed wall time as a fresh-load measurement. `load.py --limit` exists for smoke tests; never submit subset timings.

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
computed by Trino from the exact hash values. See merged redis-sql-trino PR #125. The connector also sets an explicit 20-minute
aggregation timeout (PR #127), because Redis Cloud rejects changing its server
search timeout through `CONFIG SET`. The Redis URI includes `?timeout=1200s` so Lettuce commands have the same limit.
Trino retains the same 20-minute query limit.

After a full verified run, add two JSON files under `results/YYYYMMDD/`, labeled
`Redis Cloud (Trino)` and `Redis Cloud (Trino, OSS Cluster API)`. Include all 43
three-value arrays, load time, actual data size, machine metadata, and `no-cold`.
For data size include hash/index memory and persistent log bytes where available;
do not substitute provisioned capacity or the Parquet source size. If persistent
log size is unavailable, leave `data_size` null and record measured Redis RAM
bytes separately; an AOF-enabled Cloud database reporting zero AOF bytes is not
evidence that its transaction logs occupy zero bytes. Do not create
result files until the full run and correctness checks finish.

Stop and remove the task's Trino container and delete the dedicated Redis Cloud
subscription and runner after downloading results. Deleting the subscription's
managed VPC also requires terminating the runner and deleting its security group
first. Retain source/results; discard private credential files and task SSH keys.

## Performance patch refresh

The current sweep pins connector `4aa71cea12abe7e2f1dc93a8f276418292edd915`, including safe integer-widening aggregation pushdown and per-query scan metrics. The superseded partial `83d05fc` baseline is retained under `evidence/20261007/baseline-83d05fc` and excluded from full benchmark results. The same loaded data and hardware are reused; results from different revisions are never mixed.

## Running individual queries

To run one query as a separate job while retaining earlier measurements:

```sh
RESULT_DIR=cloud-results-cluster .venv/bin/python run-one-query.py --mode cluster --query 6
```

Each job restarts Trino, clears the runner page cache and records three complete-result attempts for the selected query. Redis stays running. Existing attempts for that query are protected against overwriting. Query numbers range from 1 to 43; the cumulative result is finalized only when all 129 attempt records exist.

The earlier individual-query sweep was stopped during Q5: attempts 1 and 2 timed out, and attempt 3 was cancelled by the user. That cancelled attempt is recorded as null with its cancellation reason. At the user's request, the sweep continues through Q6-Q43 in individual jobs, using the same revision, loaded data and hardware.

## Current-code requirement

This submission pins `d83d504d65cd5b3bd14fd9bd559f5acad6ffedf2` (merged PR154), including automatic parallel scans. `install` checks the pin
against current origin/master and builds a Git archive of that exact commit,
excluding stale compiled files and local edits. It records every plugin JAR's
SHA-256 and the build image ID in `plugin/connector-build.json`.

`start-cloud` requires the pin to match live master and validates all plugin JARs.
It labels the Trino container with the revision and manifest checksum. Both query
runners recheck live master, plugin bytes, container labels and its read-only
plugin mount before testing. If master advances, update `versions.env`, rebuild,
and recreate Trino. Runs stay pinned once started; do not replace artifacts in an
active run. Network verification failures stop the run rather than using stale code.

Each results directory retains `connector-build.json`. Older results without
provenance or with another build must use a separate directory. Historical
measurements keep their original revisions: the 5M Cloud 129-output acceptance
predates automatic parallel scans; the local parallel-scan tests are separate.
The full-data latest-code OSS sweep completed on October 8, 2026 Pacific; see the measured result below.

```sh
.venv/bin/python -m unittest discover -s . -p test_benchmark_version.py
```

## Completed latest-code full-data run

All 43 queries ran three times on 99,997,497 rows at `dbcb518`. 123 outputs passed independent references; Q24 timed out on all attempts and Q34 exceeded MAX_AGGREGATE_GROUPS on all attempts. These six attempts are null. Results require `no-cold`. Fresh Arrow ingestion plus indexing was 1036.954 seconds; source download/table creation excluded. Separate 10M encoder diagnostics do not enter query timings. An actual default server API switch failed with PROVISION_FAILURE; no client-only comparison is claimed. Validation/provenance evidence is retained in `evidence/latest-20261008`; its historical result JSON is in `evidence/latest-20261008/leaderboard-result.json`.

## PR154 acceptance evidence

October 9 full-data testing of merged PR154 (`d83d504d65cd5b3bd14fd9bd559f5acad6ffedf2`) validates Q24 and Q34 on all 99,997,497 rows, three attempts each. Q24 best warm: 3.914345 seconds; Q34: 61.687396 seconds. These previously timed out and exceeded the group limit, respectively. This targeted cohort is separate from the complete older result matrix; no mixed-revision matrix is submitted.

| Query purpose | Attempt 1 (s) | Attempt 2 (s) | Attempt 3 (s) | Best warm (s) | Correctness |
|---|---:|---:|---:|---:|---|
| Q24: Earliest 10 full rows whose URL contains google | 4.065388 | 3.933026 | 3.914345 | 3.914345 | 3 independent reference matches |
| Q34: Top 10 URLs by visit count | 75.063332 | 64.139660 | 61.687396 | 61.687396 | 3 independent reference matches |
| Q35: Same URL grouping with a constant column (control) | 79.409368 | 62.152862 | 62.306080 | 62.152862 | 3 independent reference matches |

[Independent correctness, CSV checksums, plans and metrics](evidence/acceptance-20261009/README.md). Backup/restore and the complete same-driver sweep are documented below.

## Complete PR154 driver sweep: October 9, 2026 Pacific

All **43 unchanged queries, three attempts each (129 outputs), pass independent full-data validation** on 99,997,497 rows. This is one consistent connector revision, `d83d504d65cd5b3bd14fd9bd559f5acad6ffedf2`, with production JAR SHA256 `a9e069c287a027b84be4e1bbe03ef2f6025d8e843e563e49cbde7c3d6e4e70eb`. No targeted acceptance samples or older-revision timings are substituted. Q24 best warm is **2.991580s** and Q34 **62.044117s**; both previous failure cases pass all three attempts.

Trino 483, Redis Cloud 8.6, RESP3, OSS Cluster API, verified 40 shards / 1000 GB all RAM, Standard QPF, no replication, noeviction, AOF every second. Three AWS r8g.16xlarge Redis hosts plus an r7a.4xlarge Trino runner share us-east-1, VPC and physical AZ use1-az6. Data disks have 16000 IOPS / 1000 MiB/s. Trino restarts and runner page cache clears per query block; Redis stays running, so `no-cold` applies. Query limit: 1200 seconds. Best warm is the minimum of attempts 2 and 3. Persistent data size is unmeasured. No verified default-versus-OSS server comparison is available.

### Backup initialization and ingestion

This sweep used the verified compatible full-data backup. Restore plus verified index readiness took **545.174150s (9m 5s)**, versus **1036.643924s (17m 17s)** for separately measured fresh Arrow ingestion plus indexing on the same driver: **1.9015x** faster in this single-trial setup diagnostic. Restore time is not ingestion and is not reported as ClickBench `load_time`; that field retains the separately measured fresh-ingestion value, excluding download and table creation. The premature 16.445s readiness observation saw old data before asynchronous import started and is invalid and excluded.

All 40 RDB files (50,181,080,429 bytes) have verified SHA256 values. Exact restored SQL/index counts are 99,997,497, with zero index failures; post-restore Q24/Q34/Q35 outputs independently validate. The private encrypted S3 backup has 30-day object expiry and is retained after compute teardown. Raw RDB files and credentials are not published.

For future benchmark initialization, **always restore a verified compatible backup when available**. Verify every shard checksum, dataset/source/schema and Redis compatibility, exact restored SQL/index counts, zero index failures and independent query correctness. Use fresh ingestion when no suitable backup exists or when explicitly measuring ingestion performance. Keep restore setup timing separate from ingestion metrics.

| Query | Attempt 1 (s) | Attempt 2 (s) | Attempt 3 (s) | Best warm (s) | Correctness |
|---|---:|---:|---:|---:|---|
| Q1 | 2.949415 | 2.838876 | 2.839760 | 2.838876 | 3 valid outputs |
| Q2 | 0.281510 | 0.192954 | 0.185813 | 0.185813 | 3 valid outputs |
| Q3 | 6.524263 | 6.428483 | 6.478129 | 6.428483 | 3 valid outputs |
| Q4 | 4.086578 | 3.991875 | 4.009102 | 3.991875 | 3 valid outputs |
| Q5 | 106.994954 | 101.596537 | 99.663822 | 99.663822 | 3 valid outputs |
| Q6 | 71.255473 | 63.358781 | 63.014049 | 63.014049 | 3 valid outputs |
| Q7 | 67.309233 | 62.859659 | 57.794620 | 57.794620 | 3 valid outputs |
| Q8 | 2.671320 | 1.901141 | 1.954668 | 1.901141 | 3 valid outputs |
| Q9 | 108.169553 | 104.407130 | 105.166889 | 104.407130 | 3 valid outputs |
| Q10 | 111.883567 | 100.865239 | 101.657988 | 100.865239 | 3 valid outputs |
| Q11 | 116.309333 | 101.769272 | 101.259427 | 101.259427 | 3 valid outputs |
| Q12 | 110.231814 | 103.101666 | 103.428366 | 103.101666 | 3 valid outputs |
| Q13 | 71.384488 | 58.733820 | 63.422950 | 58.733820 | 3 valid outputs |
| Q14 | 109.603335 | 102.026118 | 100.548743 | 100.548743 | 3 valid outputs |
| Q15 | 83.157092 | 67.814141 | 72.072635 | 67.814141 | 3 valid outputs |
| Q16 | 107.357466 | 101.758360 | 99.840934 | 99.840934 | 3 valid outputs |
| Q17 | 108.229105 | 99.352973 | 101.241822 | 99.352973 | 3 valid outputs |
| Q18 | 108.746655 | 103.092399 | 99.390767 | 99.390767 | 3 valid outputs |
| Q19 | 112.548316 | 100.350021 | 104.333626 | 100.350021 | 3 valid outputs |
| Q20 | 0.238739 | 0.112976 | 0.105313 | 0.105313 | 3 valid outputs |
| Q21 | 4.549125 | 4.457410 | 4.460852 | 4.457410 | 3 valid outputs |
| Q22 | 14.653248 | 7.637822 | 7.606456 | 7.606456 | 3 valid outputs |
| Q23 | 14.883391 | 7.686048 | 7.678627 | 7.678627 | 3 valid outputs |
| Q24 | 3.168479 | 2.991580 | 3.005566 | 2.991580 | 3 valid outputs |
| Q25 | 88.264063 | 69.896392 | 69.610698 | 69.610698 | 3 valid outputs |
| Q26 | 67.273928 | 57.264276 | 57.938492 | 57.264276 | 3 valid outputs |
| Q27 | 80.668309 | 74.201337 | 69.456862 | 69.456862 | 3 valid outputs |
| Q28 | 90.173839 | 74.217984 | 71.970268 | 71.970268 | 3 valid outputs |
| Q29 | 73.233046 | 63.860541 | 63.317530 | 63.317530 | 3 valid outputs |
| Q30 | 66.578750 | 57.968464 | 59.927839 | 57.968464 | 3 valid outputs |
| Q31 | 112.252675 | 99.735685 | 102.151100 | 99.735685 | 3 valid outputs |
| Q32 | 116.807249 | 111.847437 | 111.193444 | 111.193444 | 3 valid outputs |
| Q33 | 113.791374 | 101.690890 | 108.469994 | 101.690890 | 3 valid outputs |
| Q34 | 73.787982 | 62.044117 | 62.563425 | 62.044117 | 3 valid outputs |
| Q35 | 73.478535 | 63.798067 | 62.253618 | 62.253618 | 3 valid outputs |
| Q36 | 70.841405 | 59.693944 | 60.705792 | 59.693944 | 3 valid outputs |
| Q37 | 2.994225 | 2.565837 | 2.373994 | 2.373994 | 3 valid outputs |
| Q38 | 2.982137 | 2.319347 | 2.202879 | 2.202879 | 3 valid outputs |
| Q39 | 0.906873 | 0.575224 | 0.551283 | 0.551283 | 3 valid outputs |
| Q40 | 4.813524 | 3.895219 | 3.910068 | 3.895219 | 3 valid outputs |
| Q41 | 1.569389 | 1.137893 | 1.026270 | 1.026270 | 3 valid outputs |
| Q42 | 1.318841 | 0.961890 | 0.912079 | 0.912079 | 3 valid outputs |
| Q43 | 2.896885 | 2.226068 | 2.197874 | 2.197874 | 3 valid outputs |

[Complete sweep evidence](evidence/full-d83d504-20261009/README.md). [Backup/restore evidence](evidence/backup-restore-20261009/README.md). The older dbcb518 result matrix is retained as historical evidence in `evidence/latest-20261008/leaderboard-result.json`, separate from the new submitted matrix.

Dedicated Redis Cloud subscription/database, all four EC2 instances, security group, data volumes, ephemeral artifact bucket, deadline Lambda/rule, IAM roles and instance profile are confirmed deleted. The private encrypted 40-file backup is confirmed retained with 30-day object expiry; local raw archives and validation records remain retained.
