# DuckFlight Flight SQL ClickBench entry

A submission harness for DuckFlight **v0.1.12**, DuckDB **1.5.6**, ADBC Flight SQL
**1.12.0**, and PyArrow **25.0.1**. Python dependencies are locked in `uv.lock`;
release extension checksums are pinned in `harness.py`. The extension contains the
proprietary DuckFlight core, so `template.json` marks this system proprietary even
though the public extension shim and this harness are MIT licensed.

The native DuckDB schema and 43 queries are copied without changes from
[ClickBench e90045879276f75cc398f1ab8a73541a7716058d](https://github.com/ClickHouse/ClickBench/tree/e90045879276f75cc398f1ab8a73541a7716058d/duckdb).
Use that revision's shared driver for a reproducible run. Measured results are
under `results/YYYYMMDD/`.
Synthetic-fixture test timings must not be submitted as ClickBench results.

## Validation

The [public extension repository](https://github.com/sidequery/duckflight-extension/tree/d81458843995f5c6d23e21ea3c6aca8d29e70c83/benchmarks/clickbench)
contains the source harness and its real-client regression tests. The full-dataset
correctness comparison is available here as `baseline.py`, described below.

Linux amd64/arm64 and macOS amd64/arm64 release artifacts are supported by the
installer. Official cold measurements require Linux and permission to drop the
OS page cache. The initial local validation was on macOS arm64.

## Full benchmark on a dedicated Linux VM

Use Ubuntu 24.04 or newer. Install `git`, `curl`, `wget`, `ca-certificates`, and `sudo` if
not already present. The installer creates an isolated Python 3.12 environment;
if needed it installs pinned uv into this directory's `.tools`, without changing
shell profiles. Use a fresh VM with enough disk for the source Parquet, DuckDB
file and spill files. ClickBench's original comparison machine is AWS
`c6a.4xlarge` with a 500 GB gp2 disk. Record the actual machine and storage used.

Copy only tracked harness files into a fresh ClickBench checkout (do not copy
`.venv` or `.state` from another machine):

```sh
git clone https://github.com/ClickHouse/ClickBench.git
cd ClickBench
git checkout e90045879276f75cc398f1ab8a73541a7716058d
mkdir duckflight
# Copy the source files from this directory into ClickBench/duckflight.
cd duckflight
set -o pipefail
./benchmark.sh 2>&1 | tee benchmark.log
./stop
```

The shared runner downloads the standard full `hits.parquet` and executes the
installation, load, size, cold/hot query and concurrent-QPS hooks. Cache clearing
uses sudo. Run on a dedicated benchmark VM: flushing its cache affects all
processes. The runner's default concurrent phase uses ten workers for 600 seconds.
Leave it enabled because all clients use one persistent server.

The load hook requires exactly **99,997,497 rows**, checkpoints, then starts the
server. It refuses to overwrite an existing `hits` table. For a new run, use a
fresh directory or a new absolute `DUCKFLIGHT_BENCH_STATE` path and rerun
`./install` to provision the extension there. Stop the old instance first.
Do not run two harness controllers against the same state directory.

## Measurement contract

- The checksum-pinned official DuckDB CLI hosts the actual extension; a Python
  supervisor manages startup, readiness and complete shutdown.
  Clients connect via ADBC Flight SQL to an authenticated, OS-selected loopback
  port. There is no TLS on loopback and no network exposure.
- Loading uses the pinned Python DuckDB API and the upstream Parquet conversion SQL.
  The database is created with `storage_version 'latest'`, matching both the
  native DuckDB and GizmoSQL upstream entries.
  Load time includes stopping/restarting the host, inserting, row-count
  validation, and checkpointing. Query execution goes through Flight SQL.
- Each query opens a connection before starting its timer. The timer includes
  execution, complete result transfer and Python row conversion. It excludes
  interpreter startup, connection/authentication, CSV formatting and reader,
  statement and connection teardown. Full results go to stdout; seconds go to
  stderr on the final line.
  Query errors exit nonzero and do not emit a success timing.
  Queries use ADBC's direct-execution API rather than DB-API's automatic prepare:
  these statements have no parameters, so a separate prepare RPC is unnecessary.
  SQL planning remains inside the measured execution.
- The shared runner runs each query three times. Before the first, it stops the
  **entire host**, clears Linux page caches, starts a fresh host and checks
  readiness. Stopping only the Flight listener would leave DuckDB caches warm.
- No query-result cache or workload-specific tuning is enabled. DuckDB uses its
  default thread/memory settings. Data size includes the database and WAL.
- The shared concurrent-QPS phase measures wall-clock throughput through the
  query hook. Unlike individual query timings, that throughput includes each
  Python client process's startup, authentication and formatting overhead.
  Interpret it as this client harness's throughput, not a persistent-client
  saturation measurement.

## Before submission

1. Run the full dataset on Linux, retain logs and record exact versions,
   architecture, CPU/RAM, VM/storage configuration and the UTC run date.
2. Run `uv run --frozen python baseline.py` after the main benchmark. It stops
   the Flight host, measures all 43 queries three times directly on the same
   DuckDB 1.5.6 database (clearing OS cache before each first try), then starts
   Flight and compares result multisets. Floating aggregates allow relative
   tolerance 1e-10 / absolute tolerance 1e-9. Differences, including possible
   LIMIT ties, are retained in `baseline.json`. Nonunique LIMIT boundaries are
   checked again with deterministic ordering for validation only; the timed SQL
   stays unchanged. Any remaining difference fails the baseline. This
   same-file baseline is not a separate standalone submission with a load time.
   It honors `DUCKFLIGHT_BENCH_STATE`; use `--state` and `--output` explicitly
   when keeping several runs so their databases and reports cannot be confused.
3. Investigate errors/OOMs. Represent failed queries as `null`, never as zero or
   a fixture result. Keep all 43 triplets and the load time/data size.
4. Convert the complete log with, for example,
   `uv run --frozen python summarize.py benchmark.log results/20261008/c6a.4xlarge.json --date 2026-10-08 --machine c6a.4xlarge`.
   Use the actual UTC run date and machine. The converter validates all 43
   triplets and required metrics and preserves failed timings as null. Validate
   against upstream before submitting. Include only full-dataset measurements
   in the dated results directory.
5. Submit the directory and measured results to ClickHouse/ClickBench. The
   maintainers decide inclusion.
