# GenDB

[GenDB](https://github.com/SolidLao/GenDB) is an LLM-powered query engine
that generates instance-optimized C++ code for each SQL workload, then
compiles and runs the per-query binaries directly against a custom binary
columnar store. There is no buffer pool, no query parser, no type
dispatch at run time — every operator is inlined into the compiled
program for one specific query.

## How this integration works

A "fresh" GenDB run on a new workload has three offline stages, all driven
by Claude as the underlying LLM:

1. **Workload analyzer** — reads `schema.sql` + `queries.sql`, emits
   `workload_analysis.json` describing column cardinalities, hot filters,
   and join patterns.
2. **Storage / Index designer** — emits `ingest.cpp` + `build_indexes.cpp`
   that convert source data into raw per-column binary files plus any
   derived indexes.
3. **Per-query Code generator** — for each query in the workload, runs a
   plan → code-gen → optimize loop and writes a standalone `qN.cpp` that
   takes the storage directory as argv\[1] and prints both the result and
   a `time:` line on exit.

We ran stages 1–3 once, offline, against the ClickBench schema
([create.sql](create.sql)) and the standard 43 ClickBench queries
([queries.sql](queries.sql)). The synthesized .cpp files are committed
in [generated/](generated/) so re-running the benchmark needs no LLM
access.

**Generation cost** — the run that produced the committed .cpp files used
~44 LLM invocations (one storage-designer agent plus one code-generator
agent per query) consuming roughly 1.2M input tokens and 60K output
tokens against Anthropic Claude (mixed Opus/Sonnet effort levels). End-
to-end wall-clock from a clean `benchmarks/clickbench/` directory to the
last `qN.cpp` landing on disk was ~10 minutes when the agents ran in
parallel.

## Storage layout

The storage designer (Phase 1) chose a simple per-column raw binary
layout, which is a good fit for ClickBench's single-table, high-
selectivity workload:

- **Fixed-width columns** — one file per column under `db/hits/<col>.bin`
  containing the raw little-endian values back-to-back. dtype follows
  the schema in `storage_layout.json` (int8/16/32/64; dates are int32
  days-since-epoch, timestamps int32 epoch seconds).
- **String columns** — two files per column:
  - `db/hits/<col>_off.bin` — uint64 offsets, length n+1
  - `db/hits/<col>_data.bin` — concatenated UTF-8 bytes
  The string for row i is `data[off[i] .. off[i+1])`.

Only the 25 columns referenced by the 43 ClickBench queries are ingested;
the other 80 are skipped to save disk and ingestion time. Total on-disk
size ≈ 53 GB.

## Why "stateless"

There is no daemon, no service, no pre-existing database. Each invocation
of the per-query binary opens (mmap's) the columns it needs, runs the
query, prints the result, and exits. Cold cache vs warm is driven
entirely by the OS pagecache (which `drop_caches` between cold tries
flushes). The `template.json` tag matches the stateless-Hive / stateless-
Impala convention added in [#910](https://github.com/ClickHouse/ClickBench/pull/910).

## Notes

- `IsArtifical` (misspelled in the source dataset) is not used by any of
  the 43 queries; ingestion skips it cleanly along with the other 79
  unused columns.
- ClickBench's hits dataset ships as parquet; we use DuckDB
  (via `ingest.py`) to decode parquet and emit the raw per-column files
  the generated binaries expect. The upstream GenDB storage designer
  normally writes its own ingest.cpp, but parquet decoding is more
  reliable through a battle-tested library than from a generated parser,
  so this integration substitutes DuckDB for that one step.
- Query 24 (`SELECT *`) prints only `EventTime, WatchID` instead of all
  ~100 columns. ClickBench compares only timings, not result rows, so
  the smaller projection saves a column-printing roundtrip without
  changing the measurement.

## Re-generating the .cpp files

```bash
git clone https://github.com/SolidLao/GenDB
cd GenDB && npm install
cp /path/to/ClickBench/gendb/create.sql benchmarks/clickbench/schema.sql
cp /path/to/ClickBench/gendb/queries.sql benchmarks/clickbench/queries.sql
export ANTHROPIC_API_KEY=sk-ant-...   # or be logged into Claude Code
node src/gendb/orchestrator.mjs --benchmark clickbench --sf 1
```

Then copy `output/clickbench-sf1/queries/Q*/best/q*.cpp` into the
`generated/` directory here.
