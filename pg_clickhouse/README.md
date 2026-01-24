pg_clickhouse ClickBench
========================

This ClickBench configuration benchmarks [pg_clickhouse] running inside
PostgreSQL and pushing queries down to a ClickHouse database. Files:

*   `benchmark.sh`: Runs the benchmark
*   `clickhouse.sh`: Installs ClickHouse and loads it with data; based on the
    [ClickHouse benchmark script](../clickhouse/benchmark.sh)
*   `create-postgres.sql`: Loads pg_clickhouse into Postgres and creates the
    foreign table
*   `postgres.sh`: Installs, configures, and starts PostgreSQL; based on the
    [PostgreSQL benchmark script](../postgresql/benchmark.sh)
*   `queries.sql`: The benchmark queries, identical to the [PostgreSQL
    queries](../postgresql/queries.sql)
*   `README.md`: This file
*   `run.sh`: Runs the benchmark; identical too the [PostgreSQL run
    script](../postgresql/run.sh)
*   `template.json`: Describes this benchmark configuration

## Environment Variables

### TOTAL_PARTITIONS

Set `$TOTAL_PARTITIONS` to the number of partitions to load into ClickHouse.
Defaults to 100.

### EXPLAIN

Set `$EXPLAIN` to a true value to run each query with
`EXPLAIN (ANALYZE VERBOSE)`.
