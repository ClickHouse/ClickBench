# Opteryx

Opteryx is an in-process SQL query engine. Query **planning** (parse, bind,
optimize) runs in Python; query **execution** is native (Cython/C++). It
queries Parquet directly from storage with no preloading or preprocessing,
which makes it well suited to ad hoc analytics.

For more information, visit:

- [Opteryx Documentation](https://docs.opteryx.app/)
- [Opteryx GitHub Repository](https://github.com/mabel-dev/opteryx-core)

This page benchmarks Opteryx (PyPI package `opteryx-core`) using the split
Parquet files provided by ClickBench.

---

## Generating Benchmark Results

### High-level Steps
1. Set up the environment.
2. Install Python and the required dependencies.
3. Download the benchmark dataset.
4. Run the benchmark script.

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
   cd ClickBench/opteryx
   ~~~

5. **Run the benchmark script**
   ~~~bash
   sudo ./benchmark.sh
   ~~~

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
`c8g.metal-48xl`) could not be launched. The published set spans 2 to 16 vCPUs
on both x86_64 (`c6a.*`, `t3a.small`) and AArch64 (`c8g.*`), which covers the
small/medium range of the standard fleet on both architectures.

### Known Issues

- On the memory-constrained instances the heaviest `GROUP BY` queries do not fit
  in RAM and spill to swap rather than failing. They complete, but two orders of
  magnitude slower — on `c6a.xlarge` (8 GB) three queries account for more than
  half the total runtime. The benchmark environment provides the 16 GB swapfile
  that ClickBench's `cloud-init` configures for every system; without it these
  queries would be `null` instead of slow.
