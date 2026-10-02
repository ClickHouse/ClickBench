# Impala with Apache Kudu

This configuration uses Apache Impala as the SQL execution layer and Apache Kudu as the persistent mutable storage layer. It is separate from `impala/`, which queries the source Parquet file directly.

## What runs

The single-node stack contains one Kudu master, one Kudu tablet server, Hive Metastore, Impala statestored, catalogd, impalad, and an Impala shell client. The Kudu table uses replication factor 1 and a composite `(WatchID, EventTime)` primary key so all 99,997,497 source rows are preserved. A view restores ClickBench's canonical 105-column order.

`benchmark.sh` invokes the shared ClickBench driver. `load` first registers the downloaded Parquet file as the source table, creates the Kudu table, and loads it through 10 sequential hash buckets. The batches are sequential rather than parallel; a single full-table `UPSERT ... SELECT` exceeded the Impala sort-node memory limit on the target machine.

## Caching and restart behavior

The result is tagged `no-cold`. The shared driver drops the host page cache before the first try, but it does not restart the stack between cold tries. Restarting the existing Impala quickstart stack loses the in-memory catalog state needed by the benchmark; the existing Parquet `impala/` configuration uses the same exception. The two later tries are warm-cache measurements.

## Storage measurement

`data-size` reports allocated filesystem blocks for all persistent Kudu master, Kudu tablet server, and Hive Metastore paths. This avoids counting unallocated extents in Kudu's sparse WAL files. Input Parquet is excluded because it is only the load source and is not part of the Kudu-backed database after loading.

## Reproduction

The dated result was measured on an AWS `c6a.2xlarge` instance with Ubuntu 24.04, 8 vCPUs, 16 GiB RAM, and a 150 GB gp3 root volume. From a fresh ClickBench checkout:

```bash
cd impala-kudu
./benchmark.sh
```

The benchmark requires x86-64 with AVX support because the Apache Impala images do not start on ARM hosts. `install` installs Docker only when absent, preserves an already-working Compose plugin, downloads the HMS dependency, and pulls the container images before the measured run.

The exact pre-run source manifest and raw logs were retained as external review evidence; they are not part of this upstream result package. The formal query sweep remains the unmodified 43-query ClickBench workload in `queries.sql`; any deterministic diagnostic queries used to investigate tied or floating-point outputs are kept outside this upstream system directory.

## Result qualification

The retained formal run preserved all `99,997,497` rows and produced all 129 timing cells. Its validator accepted Q1–Q41 and Q43; the original Q42 selected a different row at a `PageViews = 1` tie boundary because its `ORDER BY PageViews DESC LIMIT 10 OFFSET 10000` does not define an order among tied groups. A validation-only variant ordering additionally by `WindowClientWidth, WindowClientHeight` matched exactly. The formal timed SQL was not changed.

Q4's observed relative difference was `8.1792e-14`, inside the predeclared `1e-12` tolerance. Independent exact diagnostics also matched `COUNT(*)`, `COUNT(UserID)`, and `SUM(CAST(UserID AS DECIMAL(38,0)))` between the Parquet and Kudu tables.
