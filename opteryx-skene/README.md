# Opteryx

Opteryx is an in-process SQL query engine. Query **planning** (parse, bind,
optimize) runs in Python; query **execution** is native (Cython/C++). It
queries Parquet directly from storage with no preloading or preprocessing,
which makes it well suited to ad hoc analytics.

For more information, visit:

- [Opteryx Documentation](https://docs.opteryx.app/)
- [Opteryx GitHub Repository](https://github.com/mabel-dev/opteryx-core)

This entry benchmarks Opteryx on **skene**, its native columnar storage
format. It is the native-format counterpart to `Opteryx (Parquet, partitioned)`.

---

## Generating Benchmark Results

### High-level Steps
1. Set up the environment.
2. Install Python and the required dependencies.
3. Download the benchmark dataset.
4. Convert it to skene (this is the load step).
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
   cd ClickBench/opteryx-skene
   ~~~

5. **Run the benchmark script**
   ~~~bash
   sudo ./benchmark.sh
   ~~~

### Loading

ClickBench distributes the dataset as Parquet, so this entry converts it to
skene before querying. That conversion is the load step, and `Load time` is its
wall-clock — comparable to any entry that ingests the source data into a native
store, and unlike the Parquet entry, whose load performs no conversion at all.

`convert.py` performs the conversion using the writer that ships inside the
`opteryx-core` wheel. skene, draken and rugo are all packaged in that single
wheel, so the conversion needs no additional dependency and no source checkout.
Row groups are packed 16 per file at 262144 rows each, matching the engine's own
mirrors: packing is per directory rather than per source file.

The conversion runs across processes. A worker owns a contiguous range of input
files end to end and writes its own output files, because morsels hold raw
pointers and cannot cross a process boundary. Workers default to three quarters
of the cores; `-j` overrides it.

That parallelism has a cost in layout: row groups do not
span chunk boundaries, so each worker's last row group — and last file — is
short. The published mirror was built with 12 workers and holds **28 files**,
against 24 for a single-worker build of the same data, and it measures about 7%
slower across the 43 queries for that reason. `-j 1` reproduces the
single-worker layout exactly. Row count is invariant either way: it is verified
per chunk against the source footers and again on the total, and a mismatch
fails the run rather than warning.

The source Parquet is deleted once the conversion completes, so `data-size`
measures the skene dataset alone.

### Compression posture

The mirror is written with the engine's read-first ("performance") posture:
skene decodes substantially faster uncompressed or lz4-compressed than with
per-section zstd, at the cost of more bytes on disk. It is a deliberate choice
for locally attached storage, where the disk is not the bottleneck and decompression
is pure cost. Remotely read data, where bytes dominate, is written differently.

The ClickBench Parquet corpus is published pre-compressed, so
`Opteryx (Parquet, partitioned)` reads whatever that corpus contains. In
practice the two are close in size — the skene mirror is 15.39 GB against
14.74 GB of Parquet, about 4% larger.

### Python version

`opteryx-core` publishes cp314 x86_64 and AArch64 manylinux wheels and declares
no runtime dependencies, so `install` is a single binary-wheel download with no
on-box compilation and no toolchain.

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

Results are published for instance types with **32 or fewer vCPUs**. The account
used for these runs is limited to 32 concurrent on-demand vCPUs, so the 192-vCPU
machines in the ClickBench fleet (`c6a.metal`, `c7a.metal-48xl`,
`c8g.metal-48xl`) could not be launched.
