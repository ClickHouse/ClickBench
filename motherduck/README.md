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

### Caveats specific to a managed service

* **Machine label.** The shared `cloud-init.sh.in` records the *client* EC2
  instance type as the benchmark "machine". For MotherDuck the meaningful size
  is the cloud compute (warehouse) size, not the client. When running under the
  official AWS automation you will want a dedicated workflow (as
  `clickhouse-cloud` has) to inject `motherduck_token` and label results with
  the MotherDuck instance type rather than the EC2 client. The previous
  `motherduck_instance_type` knob is no longer read by this directory.
* **Per-try connection cost.** The shared runner runs one process per query
  try, so each timing includes a fresh `md:` connection + catalog load. This is
  consistent with how the harness treats every engine, but is heavier for a
  remote service than for a local embedded one.
