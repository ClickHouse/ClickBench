## MotherDuck

MotherDuck is a managed, serverless cloud data warehouse built on DuckDB. This
entry uses the shared ClickBench driver (`../lib/benchmark-common.sh`): the
benchmark VM is only a thin DuckDB client that connects to MotherDuck over an
`md:` connection, and the data lives entirely in MotherDuck's cloud.

### Prerequisite

* A [MotherDuck access token](https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/#creating-an-access-token),
  exported as `motherduck_token` (the DuckDB client also accepts the
  uppercase `MOTHERDUCK_TOKEN`).

### Running the benchmark

```
motherduck_token=<TOKEN> ./benchmark.sh
```

`benchmark.sh` sets a few `BENCH_*` variables and hands off to the shared
driver, which installs the client, loads the data, and runs each query
`BENCH_TRIES` (default 3) times.

### Driver settings (see `benchmark.sh`)

* `BENCH_DOWNLOAD_SCRIPT=""` — nothing is downloaded to the client; `./load`
  CTAS'es directly from the ClickBench parquet on S3 into MotherDuck.
* `BENCH_RESTARTABLE=no` — the engine is remote, so stopping the local client
  and dropping its page cache does nothing to MotherDuck. The shared driver's
  stop/start/drop-caches cold-cycle is skipped; MotherDuck is inherently
  "no-cold" (reflected in `template.json` tags).
* `BENCH_DURABLE=yes` — data persists in the cloud across client restarts.
* `BENCH_CONCURRENT_DURATION=0` — the concurrent-QPS test is disabled by
  default because each `./query` opens a fresh connection (so it would mostly
  measure cloud connection setup). Export a non-zero value to re-enable it.

### Script layout

The shared driver invokes these scripts in the system directory:

| script      | role                                                          |
|-------------|--------------------------------------------------------------|
| `install`   | apt Python + venv, `pip install duckdb`                       |
| `start`/`stop` | no-ops (remote service, no local daemon)                  |
| `check`     | `SELECT 1` over `md:` to confirm connectivity                 |
| `load`      | create the `clickbench` database + INSERT from S3 parquet     |
| `query`     | run one query from stdin; result → stdout, seconds → stderr   |
| `data-size` | `pragma_database_size()`, converted to bytes                 |
| `template.json` | system metadata (name, proprietary, tuned, tags)         |

The next two scripts are MotherDuck-specific helpers, not part of the shared
driver's contract:

| script             | role                                                   |
|--------------------|--------------------------------------------------------|
| `set-instance-size`| change the account's read_write Duckling size + wait   |
| `run-all-sizes.sh` | run the whole benchmark once per Duckling size          |
| `make-result`      | convert a per-size log into a committable results JSON   |

### Changing the Duckling (compute) size

The Duckling (compute instance) size **cannot** be set via SQL or the `md:`
connection string — it is an account / service-account setting changed through
the MotherDuck REST API (`PUT /v1/users/{username}/instances`). `set-instance-size`
wraps that call:

```
motherduck_token=<TOKEN> ./set-instance-size <pulse|standard|jumbo|mega|giga>
```

It (1) issues `SHUTDOWN NORMAL` so the current duckling shuts down cleanly,
(2) `PUT`s the new `read_write.instance_size` (preserving the `read_scaling`
block the PUT requires), (3) waits `SETTLE_SECONDS` (default 120, min 120)
**without touching MotherDuck** so the duckling finishes shutting down on its own
— this fixed wait is required, `md_live_duckling_size()` alone isn't enough — and
(4) double-checks `md_live_duckling_size()` reports the new size. The username is
auto-discovered via `MD_USER_INFO()`, or set `motherduck_username` to skip the
lookup. The duckdb Python package must be installed (run `./install` first).

To benchmark a single size, change it first and then run the benchmark:

```
motherduck_token=<TOKEN> ./set-instance-size mega && motherduck_token=<TOKEN> ./benchmark.sh
```

### Running across all sizes

```
motherduck_token=<TOKEN> ./run-all-sizes.sh                  # mega → pulse
motherduck_token=<TOKEN> INCLUDE_GIGA=1 ./run-all-sizes.sh   # giga → pulse
motherduck_token=<TOKEN> ./run-all-sizes.sh standard jumbo   # a subset
```

Runs proceed **largest size first**, no matter how the sizes are given. The
default set is `mega jumbo standard pulse`; **giga is excluded by default**
because some trial accounts don't have it enabled — add it with `INCLUDE_GIGA=1`
or by naming `giga` explicitly.

For each size it calls `set-instance-size`, waits for the change to stabilize,
then runs the full benchmark (reload + all 43 queries), capturing output to
`motherduck-<size>.log` and converting it (via `make-result`) to
`results/<date>/<size>.json`. Set `RESTORE_SIZE` to return the account to a given
size when the sweep finishes. Note the sweep is slow: size changes take ~2 min
(pulse/standard/jumbo) to ~10 min (giga) to take effect, and each run reloads the
full dataset.

### Producing committable results

The shared cloud-init derives a result's `machine` from the **client EC2
instance type**, which is meaningless for MotherDuck — the compute is the remote
Duckling. ClickBench supports PR-committed result files, so instead of relying on
that path we generate the JSON ourselves, labeled by Duckling size:

```
./make-result <size> [logfile] [date]     # e.g. ./make-result jumbo
```

It reads the per-size log plus `template.json` and writes
`results/<date>/<size>.json` with `machine` set to `Motherduck: <size>` (matching
the existing published MotherDuck results). `run-all-sizes.sh` calls it
automatically, so a sweep leaves a full `results/<date>/` set ready to commit.

### Caveats specific to a managed service

* **Machine label.** The shared `cloud-init.sh.in` derives a result's `machine`
  from the *client* EC2 instance type via the sink/materialized-view path. For
  MotherDuck the meaningful size is the Duckling (compute) size, not the client.
  We sidestep this by committing results directly: `make-result` labels each
  file `Motherduck: <size>`, and `run-all-sizes.sh` produces the whole set. The
  automated sink path would still mislabel a MotherDuck run, so a submission
  should rely on the committed `results/<date>/*.json` files (as the existing
  MotherDuck results do), not on a stock cloud-init run. The old
  `motherduck_instance_type` env var (which only *labeled* the report) is
  replaced by `set-instance-size`, which actually changes the compute.
* **Per-try connection cost.** The shared runner runs one process per query
  try, so each timing includes a fresh `md:` connection + catalog load. This is
  consistent with how the harness treats every engine, but is heavier for a
  remote service than for a local embedded one.
