# Concurrent ClickBench

Throughput benchmark that runs the standard ClickBench query set under
sustained concurrent load. While ClickBench itself measures cold/warm
single-query latency, this variant measures the QPS a system sustains
when N persistent clients hammer it with random queries.

## What it does

* Loads the same `hits` table as ClickBench (≈100M rows).
* Spawns **N persistent connections** (default 10).
* Each connection picks a query **uniformly at random** from the 43
  ClickBench queries and runs it, in a loop.
* Runs for a fixed duration (default **10 minutes**) after a 30-second
  warmup that is excluded from the measurement window.
* Reports completed queries, **QPS**, and latency p50 / p95 / p99 / max,
  plus a per-query breakdown (count + mean latency).

Backends:

| Backend     | Protocol | Default port |
|-------------|----------|--------------|
| ClickHouse  | HTTP     | 8123         |
| StarRocks   | MySQL    | 9030         |

The driver uses each system's native client path: stdlib `http.client`
for ClickHouse, `pymysql` for StarRocks.

## Usage

End-to-end (install, load, concurrent run):

```bash
./benchmark.sh clickhouse
# ... on a separate machine ...
./benchmark.sh starrocks
```

If the data is already loaded, run the concurrent test directly:

```bash
./run.sh clickhouse
./run.sh starrocks
```

Tune via env vars:

```bash
CONCURRENCY=20 DURATION=300 WARMUP=15 ./run.sh clickhouse
```

Or call the Python driver directly for full control:

```bash
python3 run.py --backend clickhouse \
    --host 127.0.0.1 --concurrency 10 --duration 600 \
    --queries queries-clickhouse.sql \
    --output-json result-clickhouse.json
```

## Output

Each run prints a summary like:

```
=== clickhouse  concurrency=10  duration=600s ===
completed:    18342
errors:       0
QPS:          30.57
latency mean: 327.1 ms
latency p50:  142.3 ms
latency p95:  1284.6 ms
latency p99:  3105.8 ms
latency max:  6201.4 ms

per-query (1-based index, count, mean ms):
  Q01: n=   434  mean=    8.2 ms
  Q02: n=   421  mean=   31.0 ms
  ...
```

`run.sh` also writes a JSON summary to `result-<backend>.json` and a
verbose log to `log-<backend>.txt`.

## Notes

* The 43 queries vary by ~100x in cost. Uniform-random selection means
  heavy queries (Q24, Q29, Q33, Q40) dominate latency tails, while light
  queries (Q01, Q07) inflate throughput. This is by design — it
  resembles a mixed analytical workload.
* Result rows are **transferred and discarded client-side**, not
  short-circuited server-side; this is closer to a real workload than
  e.g. ClickHouse's `FORMAT Null`.
* On the same hardware, compare **QPS** across backends. Latency
  percentiles are secondary because they reflect the random query mix.
* Default warmup is 30s; for a 10-minute measurement window this loses
  ~5% of total wall time but excludes connection ramp-up, JVM JIT
  (StarRocks), and any first-query compile cost.
