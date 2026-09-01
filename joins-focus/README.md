# Joins-Focus Benchmark

TPC-H, TPC-DS and JOB across seven database systems.

| system | version | how it runs |
|---|---|---|
| ClickHouse | 26.7.5.10 | official server image; `clickhouse client` over `docker exec` |
| DuckDB | 1.5.5 | CLI binary, no server |
| StarRocks | 4.1.4 | official image; MySQL protocol |
| CedarDB | v2026-08-20 | official image; PostgreSQL protocol |
| Doris | 4.1.3 | FE + BE containers; MySQL protocol |
| Umbra | 26.08 | official image; PostgreSQL protocol |
| Firebolt | 4.31.13 | Firebolt Core image; HTTP + SQL |

Everything runs locally in Docker.

## Running it

To load a system and then drive it by hand:

```bash
LOAD_ONLY=1 ./clickhouse/run.sh tpch     # loads, leaves the server up, prints how to connect
docker exec -it dbbench_clickhouse clickhouse client --database tpch
sudo docker rm -fv dbbench_clickhouse    # when finished
```

To benchmark a server that is already loaded — after the load above, or after a run you
interrupted — without reloading anything:

```bash
QUERY_ONLY=1 ./clickhouse/run.sh        # queries only; writes results/clickhouse/<timestamp>.json
QUERY_ONLY=1 TRIES=1 ./clickhouse/run.sh tpch    # or one benchmark, one try
```

`QUERY_ONLY` refuses to run if the server is not answering, rather than recording 238 nulls, and
it leaves the server up when it finishes. A
benchmark whose tables are not on the server reports null. `load_time` is
**carried over** from the last load in `logs/<system>.loadtimes.tsv`.

Setting both `LOAD_ONLY` and `QUERY_ONLY` is rejected.

```bash
./generate-data.sh                  # once: generate the data (SCALE=1 by default)
./run-all.sh                        # every system, every benchmark
./generate-results.sh --html        # -> report.html, opens on its own
```

Narrower runs:

```bash
SCALE=10 ./generate-data.sh tpch    # a different scale factor, one benchmark
./clickhouse/run.sh tpch            # ClickHouse, TPC-H only
./duckdb/run.sh tpch tpcds          # DuckDB, two benchmarks
./run-all.sh --systems "clickhouse duckdb" --benchmarks tpch
STATISTICS=1 ./run-all.sh           # collect statistics after loading
```

| variable | default | effect |
|---|---|---|
| `TRIES` | `6` | how many times each query runs — one cold, the rest hot |
| `DROP_CACHES` | `1` | drop the page cache before each query. `0` skips it, so no run is cold |
| `QUERY_TIMEOUT` | `300` | per-query cap **in seconds**; a query that exceeds it records null |
| `LOAD_TIMEOUT` | `1200` (ClickHouse `2400`, DuckDB `3600`) | per-table load cap; on DuckDB it bounds a whole benchmark's load, which runs in one process. On ClickHouse it is the client's `receive_timeout` — how long to wait on the server, so a long-but-progressing statement is never cut short |
| `SCALE` | `1` | TPC-H / TPC-DS scale factor (`generate-data.sh` only) |
| `CSV` | `1` | `generate-data.sh` only. `0` skips the CSV copies — they are for Umbra alone, and as uncompressed text they are far larger than the Parquet (TPC-H SF100: ~35 GB vs ~80 GB) |
| `STATISTICS` | off | collect statistics after loading. Timed **separately** and reported as `stats_time`, not inside `load_time`, so a `STATISTICS=1` run stays load-time comparable with one without it. |
| `KEEP_DATA` | off | leave a system's loaded data on disk when its run ends |
| `LOAD_ONLY` | off | start the server and load, then stop — server left running, no queries, no results file |
| `QUERY_ONLY` | off | the reverse: query a server that is **already** loaded and running. Starts nothing, loads nothing, leaves it running. Writes a results file |
| `MACHINE` | `uname -m` | label recorded in the results |

Each runner prints which cache mode it used, so a set of numbers says what it measured:

```
page cache dropped before each query (6 tries: 1 cold + 5 hot)
DROP_CACHES=0: page cache NOT dropped; the first of the 6 tries is not cold
```

The benchmark queries are run sequentially, one system at a time.

## Layout

```
generate-data.sh          DuckDB generates all three benchmarks' data as Parquet
run-all.sh                runs every system in turn, then regenerates the page
<system>/run.sh           one runner per system, self-contained
<system>/ddl/*.sql        CREATE TABLE, hand-maintained, one file per benchmark
<system>/load/*.sql       the load statements
<system>/queries/*.sql    one query per line
clickhouse/config/        the IPv4 listen override mounted into the server
data/parquet, data/csv    generated data, shared by every system
results/<system>/<ts>.json one file per run; the generator folds them per system
generate-results.sh       results/*.json -> data.generated.js -> index.html
```

The page shows one query text per position, taken from `clickhouse/queries/` — each system has
its own dialect of the same query. Override with `QUERY_SET=<dir> ./generate-results.sh`.

## Data

One generator for everything, and every system loads bytes derived from the same artifact — so
a type or a NULL cannot differ between systems by accident.

- **TPC-H** and **TPC-DS** come from the standard `dbgen`/`dsdgen` via DuckDB's extensions
  (`CALL dbgen(sf=N)` / `CALL dsdgen(sf=N)`), written straight to Parquet. The generator's own
  types are the spec's type list — `BIGINT`, `DECIMAL(15,2)`, `VARCHAR`, `DATE`.
- **JOB** is the canonical IMDB snapshot — real data, no scale factor. Its CSV is Postgres-COPY
  format, not RFC 4180, and `generate-data.sh` documents the two ways that matters.
- Umbra gets a CSV copy as well: it is the one system here with no Parquet reader.

## Schema and queries are explicit

Every system has its own `ddl/`, `load/` and `queries/` files, written out and maintained by
hand.

Two details worth knowing before editing them:

- **Column order is positional on load.** The load statements do `SELECT *` from the Parquet,
  so reordering a column in `ddl/` silently corrupts that table. Doris is the deliberate
  exception: it requires `DUPLICATE KEY` columns to be a table prefix, so its DDL puts them
  first and its load statements name every column to compensate.
- **Every table declares the spec primary key** — as `ORDER BY` (ClickHouse, StarRocks),
  `DUPLICATE KEY` (Doris), `PRIMARY INDEX` (Firebolt) or `PRIMARY KEY` (DuckDB, CedarDB,
  Umbra). All seven declare the same columns.

## Disk

Every system's loaded data is removed when its run ends, so only one system's copy is on disk at
a time. The container-based ones (ClickHouse, StarRocks, Doris, CedarDB) get that from
`docker rm -f`; DuckDB, Umbra and Firebolt keep their data in the working tree, so their runners
delete it explicitly on exit. `KEEP_DATA=1` leaves it in place when you want to inspect a loaded
database afterwards.

The generated data under `data/` is *not* removed automatically: every system reads it, so it has
to outlive them. Delete a benchmark's Parquet and CSV once all seven have run it.

## Results

Each run writes its own file, `results/<system>/<UTC timestamp>.json`, and never overwrites an
earlier one. `generate-results.sh` groups them by system and folds them into one entry per
system, taking each benchmark's rows from the newest run that has them.

The file contents:

```json
{ "system": "ClickHouse", "version": "26.7.5.10", "actual_version": "26.7.5.10",
  "machine": "x86_64", "kind": "dbbench",
  "load_time": {"tpch": 7}, "stats_time": {"tpch": 3}, "data_size": {"tpch": 480327132},
  "result": [[0.624, 0.057, ...], ...] }
```

`result` is always **238 rows** — TPC-H 22, then TPC-DS 103, then JOB 113 — so a row's position
identifies its query no matter which benchmarks a run covered. A query that could not run is a
row of nulls.

## Notes on individual systems

- **ClickHouse gets conformance settings** on every query (`join_use_nulls`,
  `group_by_use_nulls`, `union_default_mode=DISTINCT`, and so on).
- **Join spilling is off for ClickHouse** (`max_bytes_ratio_before_external_join=0`).
- **ClickHouse dates are `Date32`, not `Date`.** TPC-DS `date_dim.d_date` spans 1900-01-02 to
  2100-01-01, and ClickHouse `Date` starts at 1970.
