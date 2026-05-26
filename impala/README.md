## Apache Impala on a single Parquet file

This setup runs Apache Impala 4 via the upstream "quickstart" Docker
images, orchestrated with `docker-compose`:

- `hms`          — Hive Metastore (Derby-backed; no MySQL/Postgres required)
- `statestored`  — cluster-membership broker
- `catalogd`     — metadata cache
- `impalad-1`    — single combined coordinator + executor

The benchmark therefore reproduces on a single VM with nothing beyond
Docker installed.

**Hardware requirement:** Impala's C++ daemons (`statestored`, `catalogd`,
`impalad`) refuse to start on a CPU without AVX — they log
> This machine does not meet the minimum requirements for Impala
> functionality. The CPU does not support AVX

and exit. Only AVX-capable x86_64 machines work; Graviton/aarch64 hosts
(including under QEMU emulation, which doesn't expose AVX) are not
supported.

The ClickBench `hits.parquet` file stores `EventTime`,
`ClientEventTime` and `LocalEventTime` as Unix-epoch `BIGINT` values and
`EventDate` as an `INT` count of days since 1970-01-01. `create.sql`
registers the parquet file as an external table (`hits_raw`) and then
exposes a `hits` view that converts those columns to `TIMESTAMP` and
`DATE`, so `queries.sql` matches the canonical ClickBench query text.
