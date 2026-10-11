# Opteryx

Opteryx is an in-process SQL query engine. Query **planning** (parse, bind,
optimize) runs in Python; query **execution** is native (Cython/C++). It
queries Parquet directly from storage with no preloading or preprocessing,
which makes it well suited to ad hoc analytics.

For more information, visit:

- [Opteryx Documentation](https://docs.opteryx.app/)
- [Opteryx GitHub Repository](https://github.com/mabel-dev/opteryx-core)

This page benchmarks Opteryx (PyPI package `opteryx-core`) on data written by
its own Parquet writer. The load step rewrites ClickBench's split Parquet files
with Opteryx's writer (rugo), using the writer's default settings; queries then
run against the rewritten files. The data stays Parquet (converted on load, the
conversion counted as load time). Its counterpart is
`Opteryx (Parquet, partitioned)`, which reads the provided files as shipped.

### Load step

`load` runs `convert.py`, which reads each `hits_N.parquet` and writes it back
with `rugo.parquet.write_parquet` (one output file per input file, row counts
checked against the source). The codec, rows per row group and row groups per
block are set at the top of `load`. Only the files the writer produces are kept,
so `data-size` measures the rewritten dataset. Nothing is precomputed: the
rewrite changes layout and encoding, not content.

### Process model

Opteryx is an in-process engine, and this entry runs it the way it is deployed:
as a long-lived service. `start` launches `server.py`, a standard-library HTTP
wrapper that imports `opteryx` and waits; `query` posts each statement to it.
This is the same shape as the pandas/polars entries.

- `BENCH_RESTARTABLE=yes`: the driver stops the server, drops the OS page cache
  and starts a fresh process before every query, so try 1 is cold. Tries 2-3
  run in the same process.
- `BENCH_DURABLE=yes`: the data is Parquet on disk and nothing is loaded into
  process memory.
- `start` launches the service and nothing else: no warm-up query, and the
  dataset is not touched. `check` reads `/health` and runs no query.
- There is no query-result cache. What carries from try 1 to tries 2-3 is
  process state: imported modules and the engine's Parquet footer and schema
  caches.
- The reported time is the server-side drain of `execute_to_morsels`, the same
  span the previous process-per-query entry measured. Rendering the result as
  TSV happens after the clock stops.

---

## Generating Benchmark Results

### High-level Steps
1. Set up the environment.
2. Install Python and the required dependencies.
3. Download the benchmark dataset.
4. Rewrite it with Opteryx's writer (this is the load step).
5. Run the benchmark script.

### Detailed Instructions

1. **Start an AWS EC2 instance**
   - OS: Ubuntu 24
   - Architecture: 64-bit (x86_64 or AArch64)
   - Instance Type: `c6a.4xlarge`
   - Root Storage: 500 GB gp2 SSD
   - Advanced Details: ensure 'EBS-optimized instance' is **disabled**.

2. **SSH into the instance** (after status checks complete):
   ~~~bash
   ssh ubuntu@{ip}
   ~~~

3. **Update the package list and install Git**
   ~~~bash
   sudo apt-get update -y
   sudo apt-get install git -y
   ~~~

4. **Clone the ClickBench repository**
   ~~~bash
   git clone https://github.com/ClickHouse/ClickBench
   cd ClickBench/opteryx-parquet-rewritten
   ~~~

5. **Run the benchmark script**
   ~~~bash
   sudo ./benchmark.sh
   ~~~

### Python version

`opteryx-core` publishes cp314 x86_64 and AArch64 manylinux wheels and declares
no runtime dependencies, so `install` is a single binary-wheel download with no
on-box compilation and no toolchain.

`install` pins the release (`opteryx-core==0.9.164`, the latest release when
this entry was drafted) and fails if the imported
version differs, so a published result names the build that produced it.

### Query dialect

`queries.sql` adapts queries to Opteryx's dialect. The adaptations are syntactic
— they do not change what is computed, the rows returned, or the work the engine has to do:

- **Q19, Q43** — `EventTime` is stored as an integer epoch, so it is cast
  explicitly (`EventTime::TIMESTAMP[s]`) before `extract(minute FROM ...)` and
  before truncation.
- **Q43** — `TRUNC(<ts>, 'minute')` rather than `DATE_TRUNC('minute', <ts>)`.
- **Q29** — the `REGEXP_REPLACE` pattern and replacement use `b''` and `r''`
  literals so the backslash reference survives to the regex engine.
- **Q37-Q42** — `EventDate` comparisons cast both sides to `DATE`
  (`EventDate::DATE >= '2013-07-01'::DATE`).

### Hardware coverage

The results submitted with this entry are from `c6a.4xlarge`, the canonical
machine. Results for the other instance types in the ClickBench fleet come from
the ClickBench benchmark runs, not from submitted measurements.

### Known Issues

- On the memory-constrained instances the heaviest `GROUP BY` queries do not fit
  in RAM and spill to swap rather than failing. They complete, but two orders of
  magnitude slower — on `c6a.xlarge` (8 GB) three queries account for more than
  half the total runtime. The benchmark environment provides the 16 GB swapfile
  that ClickBench's `cloud-init` configures for every system; without it these
  queries would be `null` instead of slow.
