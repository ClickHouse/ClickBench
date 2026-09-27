# infino

[Infino](https://github.com/infino-ai/infino) is a fast retrieval engine that
runs SQL, full-text (BM25), and vector search over a single copy of your data
on object storage. Data lives as spec-compliant Parquet on S3, Azure, GCS, or
local disk, with snapshot-isolated reads and atomic commits, so anything that
reads Parquet can read it too. ClickBench exercises only the SQL path.

infino stores each table as a superfile: a valid Parquet file with its search
indexes embedded alongside the columns, so the same bytes answer SQL, keyword,
and vector queries. For ClickBench it ingests the hits data into a superfile
table, then runs as a **persistent server**, the same way the harness measures
other daemon engines: `./start` opens the table once and holds it warm behind a
unix socket, and each `./query` is a thin client. The shared driver restarts the
server before each query's cold try (`BENCH_RESTARTABLE=yes`), so try 1 is cold
and tries 2/3 hit the warm server.

The whole harness is one small Rust binary (`bench/`) that depends only on the
published `infino` crate. No Python, no per-query tuning, one schema for all 43
queries, so `tuned=no`.

## Build

```sh
./install        # installs rustup if absent, then cargo build --release
```

The release build is portable (no `-C target-cpu`), pinned to a published crate
version (`infino = "0.5.10"`) so the result is reproducible from crates.io alone.
LTO is sized to the machine by `install`: fat LTO + `codegen-units = 1` at
>= 12 GiB RAM (its single-pass link peaks ~7.6 GB), thin LTO below so the small
VMs still build. Reads use strong consistency, so a query issued right after
load sees every ingested row.

## Run (automated ClickBench flow)

```sh
./benchmark.sh   # download -> load -> start server -> per-query 3-try sweep
```

## Run manually (e.g. a 10M subset)

```sh
# Fetch N partitions instead of the full single file:
seq 0 10 | xargs -P11 -I{} wget -q --continue \
  https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet

INFINO_SRC="hits_*.parquet" INFINO_MAX_ROWS=10000000 ./load   # ingest once
./start                                                       # launch the server
printf '%s\n' "SELECT COUNT(*) FROM hits" | ./query           # result table + seconds
./stop                                                        # shut the server down
```

## Server protocol

`serve` opens the table once and answers one query per connection on
`INFINO_SOCK` (default `./infino.sock`). Timing wraps `query_sql` only, so the
socket round-trip is never counted. `./query` sends stdin to the server and
prints the query result as a text table to stdout (a bounded preview: up to
1000 rows and `CLICKBENCH_OUTPUT_LIMIT` bytes, so a huge result cannot blow up)
and the elapsed seconds to stderr (the ClickBench query-script contract). The
result on stdout is also what the online playground shows the user. `./check`
pings the server so the driver can detect it coming up and going down.

## Environment

| var | default | meaning |
|---|---|---|
| `INFINO_URI` | `./data` | backend: local path, `az://…`, `s3://…` |
| `INFINO_SRC` | `hits.parquet` | glob for source parquet |
| `INFINO_MAX_ROWS` | all | cap total ingested rows (e.g. `10000000`) |
| `INFINO_SOCK` | `./infino.sock` | unix socket the server listens on |
| `INFINO_CACHE_DIR` | `./cache` | disk cache so warm tries reuse cached column chunks |
| `INFINO_CACHE_BUDGET` | infino default (10 GiB) | disk-cache budget in bytes; `benchmark.sh` sets ~75% of RAM so the dataset stays resident |
| `INFINO_TARGET_SF_MB` | infino default (~1 GiB) | compacted superfile target size; `benchmark.sh` sets 256 for parallel scan |
| `INFINO_STORAGE_*` | — | passed as `storage_options` (e.g. `INFINO_STORAGE_AZURE_STORAGE_ACCOUNT_NAME`) |

## Type handling

infino queries its own table rather than an external parquet view, so the two
adjustments the `datafusion` variant does inline at query time are done here at
ingest (`bench/src/main.rs`):

- `EventDate` (integer day count) → `DATE`, so date-range predicates work
  without per-query casts.
- Text columns (Parquet `BYTE_ARRAY`/binary) → UTF-8, so `LIKE`,
  `REGEXP_REPLACE`, and `length` operate on strings.

`EventTime` keeps its native integer type; the queries wrap it in
`to_timestamp_seconds(...)`, so `queries.sql` is identical to the `datafusion`
variant's. Every table carries an auto-generated `_id` column, so query 24
(`SELECT *`) returns it as an extra trailing column.
