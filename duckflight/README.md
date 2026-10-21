# Duckflight

DuckDB 2.0.0 (`d54cbbe3df`) with the signed Duckflight extension containing
core-v0.1.14. The extension shim and runner are open source; the bundled core is
proprietary. Official CLI and extension downloads are checksum-pinned.

The default query client is Apache Arrow's Rust client 60.0.0, built from
checksum-pinned source and a committed Cargo.lock with Rust 1.99.0. A small checked
patch adds CSV output and execution-through-complete-fetch timing. Connection,
authentication and CSV formatting are outside the timer; planning and fetching
all Arrow batches are inside. The Python ADBC control additionally converts Arrow
to Python rows; the Rust/Python comparison does not measure identical client work.

## Run

Use a dedicated Ubuntu 24.04+ machine with sudo/root access, Git, curl, wget and
CA certificates. `./install` installs missing Linux compiler prerequisites with
apt, bootstraps pinned uv if needed, creates a Python 3.12 environment, and selects
Rust 1.99.0. Missing Rust is installed under `.tools` without changing shell
profiles. macOS requires Xcode Command Line Tools and supports functional checks;
Linux and permission to drop OS caches are required for official cold results.
Supported release artifacts cover Linux/macOS on ARM64/AMD64.

```sh
cd duckflight
set -o pipefail
./benchmark.sh 2>&1 | tee benchmark.log
./baseline --state "$PWD/.state" --output baseline.json
./validate-native --state "$PWD/.state" --baseline baseline.json --output native-validation.json
./stop
```

The standard driver downloads the source Parquet outside load timing, loads a
native DuckDB table with `storage_version 'latest'`, validates 99,997,497 rows,
checkpoints, and starts one authenticated loopback server. Load time includes that
validation and startup. Data size includes the database and WAL. No thread or
memory tuning is applied.

The shared driver stops the whole host and drops OS caches before each first
try, then runs two warm tries against the persistent host. Warm comparisons with
fresh-process embedded CLIs include their different process/cache lifecycle;
they do not isolate Flight transport overhead. Ten-worker concurrent throughput
remains enabled by default. Its wall-clock timer includes client process setup.

Use a fresh `.state` for a new dataset; the loader refuses to overwrite `hits`.
`DUCKFLIGHT_BENCH_STATE` selects an absolute alternative state directory. Never
run two controllers against the same state. `DUCKFLIGHT_BENCH_CLIENT=python`
selects the locked Python control for the entire run, including installation.

## Other storage layouts

- [`../duckflight-datalake`](../duckflight-datalake): one remote S3 Parquet object.
- [`../duckflight-datalake-partitioned`](../duckflight-datalake-partitioned): 100 remote S3 Parquet objects.

Each entry has its own template, queries, hooks and state. The implementations,
Python environment and Rust client are shared here. Lake hooks automatically use
`../lib/dataset-bucket.sh` to select the region-local public mirror. Explicit
`DUCKFLIGHT_BENCH_PARQUET_SOURCE` and `DUCKFLIGHT_BENCH_S3_REGION` overrides remain
available. `CLICKBENCH_DATASET_BUCKET` forces the shared helper's bucket selection.

## Results and validation

All three 2026-10-21 entries contain 43 queries × 3 valid timings on c6a.4xlarge
with 500 GB encrypted gp2 storage. Every result was checked against direct DuckDB;
nonunique LIMIT boundaries were checked with validation-only tie breakers while
timed SQL stayed unchanged. Native concurrent runs were aborted after deadline
overruns and spilling; their QPS/error metrics are unavailable. Lake throughput
was explicitly skipped (`BENCH_CONCURRENT_DURATION=0`). All submitted throughput
fields are null; no throughput claim is made.

The converter requires explicit phase status before accepting non-null QPS:

```sh
./summarize benchmark.log results/YYYYMMDD/machine.json --date YYYY-MM-DD --machine machine \
  --throughput-status throughput-status.json
```

Only `{"status":"complete"}` preserves throughput. Aborted/failed phase statuses
null both metrics. Alternatively use `--throughput-unavailable 'reason'`. Skipped
phases already containing null metrics need no status file. Do not publish raw
metrics from an aborted phase or regenerate them without its status.

Functional tests (after installation):

```sh
uv run --project . --frozen python -m unittest discover -p 'test_*.py'
```

Small-fixture tests do not produce publishable ClickBench timings. Never copy
runtime state, credentials, private keys, controllers or source archives into a
submission. Preserve historical results when adding a new dated result.
