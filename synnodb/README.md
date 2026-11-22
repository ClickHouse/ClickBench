# SynnoDB

[SynnoDB](https://synnodb.com/) ([source](https://github.com/SynnoDB/SynnoDB),
[paper](https://arxiv.org/pdf/2603.02001)) is a drop-in replacement for DuckDB that accelerates a
known SQL workload with a bespoke C++ query engine. An LLM agent, the "factory", writes the engine
for the statements of the workload and checks the results of every statement against DuckDB. At
run time `import synnodb as duckdb` routes the statements the engine knows to the engine and
everything else to DuckDB.

This entry is `tuned`: the engine was written for exactly the queries of this benchmark. A
statement that differs from them in anything but formatting is answered by DuckDB.

## How it runs in the benchmark

- The engine was generated once, offline (see below). Its C++ sources are in [engine/](engine/),
  so the benchmark needs no access to an LLM. `install` installs SynnoDB and compiles the sources
  for the machine with SynnoDB's own compiler driver (`build_engine.py`): `g++ -g -O3 -flto`, no
  `-march`.
- `server.py` is one long-lived process that holds a `synnodb.connect("hits.db", ...)`
  connection, the way an application would. The data is in a DuckDB file, loaded as in the
  [duckdb](../duckdb/) entry.
- The engine keeps its own copy of the table in memory. SynnoDB loads it on the first statement
  of a connection: it exports the whole table from DuckDB as Arrow into `/dev/shm`, and the
  engine process builds its structures from that image. The benchmark restarts the server
  before the first run of every query, so **the cold run includes this reload**; the hot runs do
  not.
- `load` builds `hits.db`, loads the engine, and then verifies it: every query the engine
  implements runs on the engine and on DuckDB, and the results are compared with the comparison
  SynnoDB's factory validates an engine with (`engine_matches_duckdb` in `server.py`). The
  queries that agree are the ones the engine serves in the timed runs; the others go to DuckDB.
  The lists are printed to the log. `load` fails, and the benchmark stops, if the engine cannot
  be loaded or agrees with DuckDB on nothing, so that timings of DuckDB are never reported under
  the name of SynnoDB.
- In the timed runs SynnoDB's router does not execute the routed statements on DuckDB a second
  time (`cross_check_rate=0.0`; by default it does so for the first ten executions of every
  statement and for a tenth of the later ones).
- The reported time is the wall-clock time of `execute` and `fetchall` on the drop-in
  connection. For a statement routed to the engine this is more than the time inside the engine:
  for every statement SynnoDB copies the engine's query library (27 MB, as it is built with
  debug information) and loads the copy anew, which took about 0.1 s where the engine was
  generated and dominates the short queries. The time inside the engine is in the output of
  `query` as `engine_ms`.
- The engine runs with the number of threads it was generated and validated with, 16. DuckDB
  uses all cores for the statements it answers.
- Data size is the size of `hits.db`. The engine's copy exists in memory only.

### Memory

The table is about 67 GiB as Arrow. While the engine is loaded, the machine holds that image in
`/dev/shm`, the engine's own structures (all 105 columns, an estimated 60 GB), DuckDB's buffers
(limited here to 20% of the RAM) and, for the duration of the export, a second copy of the image
in the server. This fits in the 384 GB of the `metal` machines and does not fit in the smaller
ones, where SynnoDB does not register the engine and `load` fails.

## The engine

The engine in [engine/](engine/) is the output of SynnoDB's factory at commit
[`5efc948`](https://github.com/SynnoDB/SynnoDB/commit/5efc9485f845247b4ddb0d63492a20d107b696f5),
run by [generate.py](generate.py). The script follows SynnoDB's own ClickBench notebook
(`tutorials/gen_clickbench_demo.ipynb`): it registers the workload from a DuckDB database and
runs the stages `createStoragePlan` and `createBaseImpl` with in-memory storage. The notebook
uses ten parameterized rewrites of ClickBench queries; this uses the benchmark's queries as they
are.

In `createBaseImpl` the factory plans the work, writes the loader, and then for every query
writes its implementation and compares its result with DuckDB's on three subsets of the data
(2%, 10% and all of the registered table), before a final pass over all queries and a benchmark
against DuckDB. A published engine has passed all of these. This run took 453 requests to the
model and four hours.

SynnoDB's notebook warns that an engine generated for a fixed set of queries could store their
answers instead of computing them. This one does not: its sources were reviewed for that, and
its results agree with DuckDB's on a second sample of a different size (see 3 below).

The engine implements 38 of the 43 queries. The other five were not given to the factory and are
answered by DuckDB:

- Q18 (`... GROUP BY UserID, SearchPhrase LIMIT 10` without `ORDER BY`): any ten groups are a
  correct answer, so the factory's checker cannot compare the engine's with DuckDB's.
- Q25, Q27 and Q43: they order by an expression that is not a column of the result
  (`ORDER BY EventTime`, `ORDER BY DATE_TRUNC('minute', EventTime)`), which the checker does not
  support (it fails with an assertion).
- Q24 (`SELECT * ...`): left out so that an in-memory engine would not have to hold all 105
  columns for one query. The loader the factory wrote holds all of them anyway.

Q32 and Q33 (`GROUP BY WatchID, ClientIP ... ORDER BY c DESC LIMIT 10`) are implemented, but
whether they are served depends on the data: where nearly every group has `c = 1`, the ten rows
are an arbitrary choice among millions of tied ones, which the comparison cannot confirm, so
DuckDB answers them. That is the case on samples of the table.

Query numbers here are line numbers in [queries.sql](queries.sql), starting from one.

`engine/` is the directory the factory published, without the binaries (`db`, `build/`):

- `manifest.json` lists the statements the engine answers; `storage_plan.txt` and
  `base_impl_todo.txt` are the factory's design notes; `queries.md` is the workload as the
  factory saw it.
- `db_loader.*` and `query<N>.*` were written by the model, and it extended `column_ingest.hpp`.
- The other files are SynnoDB's scaffold, copied by the factory into every engine.

## How this run differs from a regular SynnoDB run

A regular run needs an API key for the model and, for this table, an x86-64 machine with a few
hundred GB of memory, because the factory validates the engine on the full data in memory.
Neither was available, so:

1. **The model was served through a local endpoint.** SynnoDB's factory talks to any
   OpenAI-compatible endpoint (`LLM_API_BASE`). Here the endpoint handed every request of the
   factory, unchanged, to an agent of [Claude Code](https://claude.com/claude-code) running the
   Claude Sonnet 5.5 model, and returned the agent's single tool call or message as the
   completion. The factory itself, its prompts, tools, checks and supervisor, ran unmodified,
   apart from the two changes below (4 and 6). The agents worked in 21 shifts; each continued
   from the transcript of the conversation and a note of the previous one.
2. **The agents were given facts about the deployment** that the factory could not know here,
   as hard requirements for the code:
   - the sources will be compiled with the same flags on x86-64 and AArch64, so only portable
     C++ is allowed: no intrinsics, inline assembly or `#pragma GCC target`;
   - the registered dataset is a 5% sample of a table of about 100 million rows, so nothing
     measured on it (row counts, cardinalities, value ranges, sizes) may be built into the code,
     and whatever grows with the data needs 64-bit offsets and counters;
   - no result may be hard-coded or forced to match (stated explicitly from the sixteenth shift
     on, when Q32 could not be validated; see 6).

   A regular run measures the full data and is allowed to specialize the engine for it. This
   engine is specialized for the queries. The exception: the loader stores 17 flag columns in
   one byte and gives ten dictionaries 16-bit identifiers, as the sample suggested, and refuses
   to load data that does not fit. The full table does fit; this was checked.
3. **The data was a 5% sample**: 4,996,920 rows, a Bernoulli sample of `hits.parquet` with the
   types of `create.sql`. Before the benchmark the engine was also run, through the scripts of
   this directory, on another, 20% sample (about 20 million rows), where 36 of its 38 queries
   agreed with DuckDB and the other two were Q32 and Q33. It has never run on the full table;
   the check in `load` is its first validation at that scale.
4. **The machine was AArch64** (96 cores, shared with other jobs and heavily loaded), although
   SynnoDB supports only x86-64 so far: the thread pool of its scaffold includes `<immintrin.h>`.
   `patch_thread_pool.py` replaces the include with a guarded one that gives the spin-wait hint
   on AArch64; `install` applies it too, and it changes nothing on x86-64. The factory judged the
   performance of the engine from timings taken on that loaded machine.
5. **Only the base implementation was generated**, with 16 threads. The later stages of SynnoDB,
   `runOptimLoop` and `addMultiThreading`, which tune every query further, were not run. SynnoDB's
   notebook does not run them either; it estimates ten hours for the first of them for ten
   queries.
6. **The factory's checker was allowed to look further for tied rows.** When a `LIMIT` cuts
   through rows tied on the sort keys, the checker re-runs the query on DuckDB with a larger
   `LIMIT` to collect all of them, and requires the engine's rows to be among them. It gives up
   at 1024 times the `LIMIT`, and then demands DuckDB's arbitrary choice, which no engine can
   reproduce except by copying it. On the sample that happened to Q32 and Q33 and would have
   ended the run. The cap (`_MAX_WIDEN_FACTOR` in `router/adapt.py`) was raised to 2^20 during
   the generation. The benchmark uses SynnoDB as it is, with the original cap.

So the results here show what SynnoDB's factory produces under these constraints, not the best
it can do. To regenerate the engine without them, run [generate.py](generate.py) on a suitable
machine with `--db` pointing to a DuckDB database of the full table and `--exclude 18,24,25,27,43`,
and replace `engine/` with the published directory (without `db` and `build/`).

`install` installs SynnoDB with its `factory` extra, although the benchmark never runs the
factory: at this commit the code that serves an engine imports modules of it.

## License

SynnoDB is distributed under the
[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0).
The files in `engine/` are SynnoDB's scaffold and the output of its factory, and are distributed
here under the same terms.

Required Notice: Copyright 2026 SynnoDB
