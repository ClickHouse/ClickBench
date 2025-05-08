# DemoBench: a Benchmark For sql.clickhouse.com

Based on [ClickBench](https://github.com/ClickHouse/ClickBench/#results-usage-and-scoreboards). We stand on the shoulders of giants.

## Overview

This benchmark aims to measure the performance of sql.clickhouse.com over time as we upgrade versions and change default settings. Queries are based on the example queries in the public demo environment [sql.clickhouse.com](sql.clickhouse.com). These queries include those in docs and blogs. **As of '2025-05-08' this is over 250 queries over 35 datasets.**

## Goals

To assess the impact of verion upgrades and setting changes for sql.clickhouse.com. As well as validating queries still execute, we confirm performance does not degrade.

Note: We donot confirm query result correctnesss. This is challenging as data is updated daily for many datasets. We simply confirm the query executes.

We aim to identify where user experience will be better/worse and the types of queries most impacted.

## Assumptions

Performance can be dramatically different based on specific user quotas and settings. We assume `demo` user settings without limitations on query throughput. We only test queries which execute successfully based on the quotas and limits applied to the `demo` user. This user `demobench` is created on all clusters - [role]() and [user definition]().

We only execute queries which are listed in the query examples on [sql.clickhouse.com](sql.clickhouse.com).

Queries are executed from a machine in the same aws region as the cluster to minimize latency. We rely on `SYSTEM DROP FILESYSTEM CACHE` to clear the FS cache between executions.

## Limitations

The limitations of this benchmark allow keeping it easy to reproduce and to include more systems in the comparison. The benchmark represents only a subset of all possible workloads and scenarios - specifically it only tests example queries of the demo environment.

## Contribution

Queries execute against a child service of sql.clickhouse.com. This has the **same Memory and CPU** as the parent but idles after 1hr if inactive. This aims to ensure isolation from the main environment and ensure users are not impacted by tests and vise versa.

Child service:

```htw00czilh.us-central1.gcp.clickhouse-staging.com``

### How To Add a New Result

Set the following:


```bash
# optional should be defaults
export CLICKHOUSE_HOST=htw00czilh.us-central1.gcp.clickhouse-staging.com
export CLICKHOUSE_USER=demobench
# SET!
export CLICKHOUSE_PASSWORD=<password>
```

The password for `demobench` user can be obtained from the PME team (#product-marketing) in slack. This user is readonly.

To add a test run, simply run `benchmark.sh`.

This script will generate a `<timestamp>.json` file. You may rarely modify the contents of this file:

- `machine` - amount of RAM e.g. `240 GB` - per node.
- `cluster_size` - number of nodes
- `comment` misc e.g. any fining tuning performed.

Other fields should be automatically completed.

Move `<timestamp>.json` to `./results`.

### Useful scripts

#### Update queries

```bash
./update_queries.sh
```

This produces a new file `queries.sql.new`. Result order should be deterministic across executions - this allows comparison of queries across test runs.

Replace `queries.sql` with `queries.sql.new` once you are satisfied all queries execute (see validation below).

### Validate queries

Validates all queries in `queries.sql` execute.

```bash
./validate_queries.sh
```
