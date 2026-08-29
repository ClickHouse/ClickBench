# pgrust

[pgrust](https://github.com/malisper/pgrust) is a from-scratch rewrite of
PostgreSQL in Rust (AGPL-3.0), wire- and SQL-compatible with PostgreSQL 18.3
(`SELECT version()` reports `pgrust 0.2 (PostgreSQL 18.3 compatible)`).

Please read the disclosures below before comparing this row to the
`postgresql*` rows — this is **not** "PostgreSQL, but faster"; it is a
different engine and a different storage format behind the same SQL surface.

## Disclosures

- **Columnar storage, not Postgres heap.** `create.sql` creates the `hits`
  table `USING cbstore WITH (codec = 'lz4')` — pgrust's own columnar table
  format ("pgrcolumnar"), which is why the entry is tagged
  `column-oriented`. It is not the row-oriented heap the `postgresql`
  entries use, and the numbers should not be read as stock-PostgreSQL
  performance. (Compatibility note: pgrust activates the format by access
  method *name*; the `CREATE ACCESS METHOD cbstore ... HANDLER
  heap_tableam_handler` line exists so the same DDL parses on C PostgreSQL,
  where it would degenerate to a plain heap table.)
- **Maturity.** pgrust is an experimental system and is **not
  production-ready**. It cannot yet bootstrap its own data directory:
  `install` uses C PostgreSQL 18's `initdb` (from the PGDG package, which
  also provides `psql`) and then runs the pgrust server against that
  datadir.
- **Build provenance.** `install` downloads the official published v0.2
  release binary for the machine's architecture
  (<https://pgrust.com/downloads/v0.2/>, sha256-verified). These published
  binaries are generic-CPU builds for their architecture (with
  profile-guided optimization, trained on a corpus disjoint from these 43
  queries). The results submitted here come from that published binary,
  i.e. exactly what `./benchmark.sh` reproduces.
- **Required settings.** `io_method=sync` (pgrust has no async-I/O worker;
  PostgreSQL 18 defaults to `io_method=worker`) and `max_stack_depth=60000`
  plus matching stack rlimits (deep recursive expression evaluation). These
  are requirements, not tuning. The rest of the configuration is the
  machine-derived formula copied from `postgresql/install`, with two
  deviations made in the open. **`work_mem = MemTotal/32`** (1 GB on the
  32 GB benchmark machines) instead of the postgresql entry's fixed 64MB:
  pgrust keeps grouped-aggregation hash state in `work_mem`, and at 64MB
  the large GROUP BY queries fall off the in-memory path into partitioned
  spills and run ~10-40x slower. **`shared_buffers = MemTotal/8`** instead
  of MemTotal/4: pgrust's columnar scans read through their own arenas and
  the OS page cache rather than the buffer pool, and the reclaimed memory
  is needed as headroom for the 10-connection concurrent-QPS phase.
  `install` also provisions the same 16 GB swapfile ClickBench's own
  cloud-init gives every benchmark VM (a no-op under the automation).
  Everything else is the shared formula.
- **`pgrust.condition_cache = on` — enabled for parity with ClickHouse,
  and disclosed.** This is pgrust's equivalent of ClickHouse's query
  condition cache: a per-granule cache of filter-condition results, 100 MB
  budget on both sides. ClickHouse ships it **default-on since 25.4**
  (`use_query_condition_cache = true`, `src/Core/Settings.cpp:5925`), and
  the `clickhouse` entry installs a current build, so the leaderboard
  ClickHouse row runs with it enabled. pgrust's is off by default in v0.2;
  enabling it here puts both systems on the same footing. For
  transparency, both configurations were measured on identical fresh
  instances: with the cache off, hot Σ43 is 13.18 s (vs 11.91 s on), and
  the entry scores ~4% ahead of ClickHouse's published c8g.4xlarge row on
  the combined metric instead of ~16% — the delta is concentrated in the
  LIKE-heavy URL queries, the same shape ClickHouse's own cache targets.
- **Load path: parquet.** The dataset is loaded from the single
  as-published `hits.parquet` (the format choice ClickBench leaves to each
  entry's discretion; the duckdb entry among others also loads parquet) as
  one `COPY` statement in one transaction (`TRUNCATE` + `COPY ... FREEZE`,
  then `VACUUM ANALYZE`), matching the shape of `postgresql/load`.
  `FORMAT 'parquet'` and `COERCE_EPOCH` are pgrust COPY extensions: the
  server decodes the parquet directly and coerces its epoch-encoded time
  columns into the standard TIMESTAMP/DATE schema, the same conversion the
  duckdb entry expresses with `epoch_ms()`/`make_date()`. `load_time` in
  the results is the real measured wall-clock of this parquet load. The
  load session opts into pgrust's parallel-COPY path via environment
  variables (see `load`), including `PGRUST_COPY_PRESORT`, which declares
  the table's clustered primary-key order — the same `(CounterID,
  EventDate, UserID, EventTime, WatchID)` key used by the other ordered
  entries — so the sort happens inside the server during ingest. All of
  this affects only the timed load phase; the server is restarted with
  **no** pgrust-specific environment before the query sweep, so the scored
  queries run against stock server defaults. (Loading from `hits.tsv` with
  a plain `COPY hits FROM ... WITH (FREEZE)` also works in v0.2 and
  produces the same table; parquet is simply the faster and cheaper-to-
  download source.)
- **Cold runs are true cold runs.** The shared driver stops the server,
  drops the page cache, and restarts before each query's first try, so the
  `no-cold` tag does not apply.
- **Results are submitted for c8g.4xlarge (arm64) only.** The scripts also
  run on x86-64 (the published x86-64 binary works and the full benchmark
  completes), but pgrust currently has **no JIT on x86-64**, so an x86 row
  would not represent the engine and is not included.
- **Known defect visible in the concurrent-QPS numbers.** Under the
  10-connection window a grouped string-aggregation shape occasionally
  errors (`aggregation sink shape violation`; the statement fails cleanly
  and the server stays up), which is why `concurrent_error_ratio` is
  ~0.005 rather than 0. It is a known v0.2 defect tracked on the pgrust
  side.

## History

An earlier attempt to add pgrust (v0.1) to ClickBench ([PR
#983](https://github.com/ClickHouse/ClickBench/pull/983)) failed: v0.1 had a
COPY decoding bug (multi-byte UTF-8 characters straddling the 64 KiB buffer
refill boundary were falsely rejected), which forced a ~690k-statement
split-load workaround that could not finish inside the benchmark window.
v0.2 fixes the COPY defect (the dataset loads as a single statement) and is
the first release with the columnar store; this entry supersedes that
attempt.

## Usage

```bash
./benchmark.sh
```
