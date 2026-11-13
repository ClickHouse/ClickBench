# Randomized ClickBench

A variant of ClickBench that cannot be overfitted. Instead of the fixed 43
queries on the fixed dataset, every run takes new random queries, written by a
language model, on a new random dataset, made from the original one by
`clickhouse-obfuscator` with a random seed. Nobody knows the queries or the
data before the run, so there is nothing to tune a system for, except being
good at analytical SQL in general.

Because the queries change from run to run, results of different runs are not
comparable. The unit of the benchmark is a **group**: several systems (for
example, ten) on several machine types (for example, two), all with the same
queries and the same data. The comparison is within the group.

## How it works

1. **Queries.** The launcher (a GitHub Actions job) asks a model for several
   batches of candidate queries, three times as many as needed. Every batch
   has its own prompt with randomly drawn parameters: a persona, the SQL
   features to emphasize (joins, `IN` and `EXISTS` subqueries, correlated
   subqueries, window functions, CTEs, set operations...), the columns to
   prefer, a few random words and a nonce. The PRNG is seeded with the seed of
   the group. The current models don't accept sampling parameters such as
   temperature, so the prompt is the source of entropy.

   Every candidate runs with the pinned ClickHouse on a small dataset of the
   same kind. A candidate is dropped if it is not a single `SELECT` with
   `ORDER BY`, aggregates large integers with `SUM`/`AVG` (the result would
   depend on overflow), fails, takes too long, returns no rows or more than
   100, or returns different results with different numbers of threads and
   block sizes (the result is not fully determined). It is also run in DuckDB on the same
   sample and dropped if DuckDB fails or returns another result (compared as
   the results of the systems are): a second implementation of the standard
   catches the queries on which ClickHouse, the reference, is wrong (as with
   some correlated subqueries) or deviates from the standard, and those whose
   meaning is ambiguous. For ClickHouse, `LENGTH`, `SUBSTRING`, `LOWER` and
   `UPPER` are rewritten to their character-wise UTF-8 variants
   (`lib/sqlrewrite.py`), as the standard defines them. The final set is sampled
   from the valid candidates to cover the features evenly
   (`generate-queries.py`).

2. **Translation.** The queries are written in portable SQL. A system whose
   ClickBench `queries.sql` differs from ClickHouse's gets them translated by
   the model (`translate-queries.py`). The model learns the dialect from the
   system's own ClickBench entry, its 43 queries side by side with
   ClickHouse's, and from its `create*` files. For a system that doesn't
   speak SQL (Rayforce), `random/systems/<system>/docs` lists the
   documentation of its language. A query that the target can't express
   counts as an error of the system.

3. **Data.** Every machine generates the dataset itself, from the seed of the
   group (`lib/generate-data.sh`). It downloads the 100 files of the original
   partitioned dataset and takes the model of the obfuscator committed in
   `models/<ClickHouse version>/` (trained by `lib/train-model.sh` on a sample
   of 2 million rows; a model has no seed, only the statistics of the data).
   Then it transforms every file in parallel, with the same model and seed,
   looping over the source as many times as needed for the requested number
   of rows (one billion by default). Every value of a column is transformed
   with a key derived from the seed and the column name, so the data stays
   consistent across files: a `UserID` is the same in all of them. With the
   same seed and ClickHouse version, every machine gets the same data. The
   files are written in the format the system loads, with the names and the
   physical layout of the original files (`lib/make-format.sh`), so the
   system's own load scripts work unchanged.

4. **Run.** The system is installed, started and loaded with its own scripts
   from the main benchmark. Then the dispatcher (`lib/driver.py`) takes the
   list of queries and repeats it (3 times by default). It orders the list
   pseudorandomly, by a hash of the query id, the repeat number and the seed,
   which gives the same order on every system. It hands every query to the
   next free worker (4 by default). There are no cold and hot runs; what
   counts is the total time. Every execution records its time, its status,
   and its output in the system's own format.

5. **Validation.** After the run, the system is stopped. ClickHouse computes
   the reference results on the same data, with settings that give the
   standard SQL semantics (`lib/reference-settings`), and every output is
   compared with them (`lib/validate.py`). The outputs come in many formats
   (tables with borders, CSV, JSON, S-expressions), so the comparison doesn't
   parse them. It looks for the values of the reference, cell by cell, in the
   same order, with only separators in between. It tolerates other notations
   of numbers, float precision, booleans as `true`/`false`, ISO times,
   differences of escaping and quoting, and a few mangled characters (U+FFFD).
   An execution is `ok`, `wrong` (with "order" if only the order of the rows
   differs), `error`, `timeout`, `unsupported`, or `unverified` (no reference
   result).

The machine sends one JSON document with all of this to the sink
(`sink.data`, `kind = 'random-benchmark'`). `report.py` builds the comparison
of the group.

## Running

Run the **Run the randomized benchmark** workflow with the systems and the
machines. It needs the repository secret `ANTHROPIC_API_KEY` (or
`OPENAI_API_KEY` with `llm: openai`). The job summary shows the group id.
When the machines are done, run **Report the randomized benchmark** with the
group id.

From a checkout, with AWS credentials:

```bash
SYSTEMS="clickhouse duckdb-parquet-partitioned rayforce" MACHINES="c6a.4xlarge c8g.4xlarge" random/launch.sh
random/report.py <group>
```

`DRY_RUN=1` generates and translates the queries without launching anything.
Without an API key, `RANDOM_LLM_BACKEND=claude-cli` uses the local `claude`
command.

Parameters (workflow inputs, or environment variables of `launch.sh`): the
number of rows (`RANDOM_ROWS`, default 1000000000), of queries
(`RANDOM_QUERIES`, 100), of concurrent workers (`RANDOM_PARALLEL_QUERIES`, 4),
of repeats (`RANDOM_REPEATS`, 3), and the time limit of a query
(`RANDOM_QUERY_TIMEOUT`, 600 s).

## The report

For every machine type, the systems are ranked by the **geomean** of their
relative times, which is close to the ClickBench page, except that it takes
the average time of every query instead of the best one. The average accounts
for the concurrency and smooths over the first, colder runs.

1. For every system and query, take the average time of its runs. A failed
   run (a wrong result, an error, a timeout, a query the system can't
   express) counts as 5× the slowest correct run of that query in the group.
2. Divide it by the best system's average as `(0.01 + time) / (0.01 + best)`,
   with the constant of ClickBench, so that very short queries don't
   dominate. Queries on which every system fails are skipped.
3. Take the geometric mean of these ratios over the queries. 1 means the best
   on every query; lower is better.

The table also shows the **total time** (the wall clock of all runs with the
concurrent workers), the **penalized time** (the total time plus the query
timeout for every failed run, divided by the number of workers), the counts of
correct, wrong, failed and unverified runs, the load time and the data size.
Then comes a matrix of the queries that failed somewhere. If most systems
disagree with the reference on a query, the report says so: the query or the
reference may be wrong. The formulas are in `lib/metrics.py`.

`report.py <group> --output <dir>` also writes `report.html`, a
self-contained page in the style of the ClickBench page (`lib/report_html.py`).
It has selectors of the machines, the systems and the metric, recomputed for
the selected systems, the summary with the bars of ClickBench, the detailed
comparison of queries and systems colored as on ClickBench, and every query in
detail: its SQL, the translation for every system, the time and status of
every run, the errors and the beginning of the outputs. The workflow **Report the randomized benchmark** publishes it
on pastila.nl (`--publish`), links it in the job summary, and keeps it in the
artifact.

## Stored results

Every group is saved in the repository as one file,
`results/YYYYMMDD/<group>.json` (the day the group was launched; several groups
can run on a day). It holds the parameters of the group, the queries with
their SQL, features and descriptions, and for every system and machine the
translations, the load time, the data size, the total and penalized time, the
geomean, the reference times and every run of every query (status, start,
time, the time reported by the system, the error, and the beginning of the
output of a wrong result). Systems without a result are listed with the error
from the log of their machine.

The workflow **Collect the randomized benchmark results** runs every hour. It
writes again the files of the groups with new results in the sink
(`collect-results.py`) and publishes them with a pull request that is merged
(`collect-new-results.sh`), as the collector of JSONBench does.

## Adding a system

Only reasonably mature systems take part. A system can take part if:

- it loads one of the generated formats: its `benchmark.sh` sets
  `BENCH_DOWNLOAD_SCRIPT` to `download-hits-parquet-partitioned`,
  `download-hits-parquet-single`, `download-hits-tsv`, or `download-hits-csv`
  (not a remote source),
- its `./query` prints the whole result, all rows and full values,
- several `./query` can run at once,
- its `./load` doesn't check for the exact row count of the original dataset.

`random/systems/<system>/` adapts a system without changing its main entry:

- any file except the ones below is copied over the system's directory on the
  machine; for example, `duckdb*/query` prints CSV (the default mode shows at
  most 40 rows) and opens the database read-only, so that queries can run
  concurrently,
- `config`: `TRANSLATE=yes|no` overrides the choice of translation, and
  `QUERY_SUFFIX` is appended to every query: ClickHouse uses it for the
  settings of the standard semantics (`join_use_nulls` and others),
- `notes.md`: notes for the translator,
- `docs`: URLs of the documentation of the system's language, for the
  translator.

## Timings and costs

On this kind of hardware, the obfuscator makes about 35,000 rows per second
per core. A billion rows takes about 35 minutes on 16 vCPUs. The machines
have a 2 TB gp3 volume: the TSV of a billion
rows is about 750 GB. The reference takes a few minutes to load and runs every
query once. The launcher spends about 10 to 20 minutes on generating and
validating the queries.

## Models of the obfuscator

`models/<version>/model.bin.zst` is the model of `clickhouse-obfuscator` for
that ClickHouse release (the file format depends on the version). The launcher
pins the version of the newest model, so the machines don't train. For a new
version, run `RANDOM_CLICKHOUSE_VERSION=<version> RANDOM_CLICKHOUSE=<its binary>
lib/train-model.sh <work dir>` and commit the result. Without a model for the
pinned version, every machine trains its own on the same sample, which gives
the same model and takes a few minutes. The file holds the uncompressed model
compressed with `zstd -9` (the obfuscator itself saves it with ZSTD level 1),
about 30 MB for 2 million rows. Its integers are native little-endian, the same
on x86_64 and aarch64.

## Testing locally

Every part runs locally: `lib/generate-data.sh` and `lib/make-format.sh` with
a small `RANDOM_ROWS` and `RANDOM_SOURCE_FILES`, `generate-queries.py` with
`RANDOM_LLM_BACKEND=claude-cli` on a sample database made by
`lib/reference.py load`, and `lib/run-system.sh` with `RANDOM_SYSTEMS_DIR`
pointing to test systems and `RANDOM_CLICKHOUSE` to a ClickHouse binary.
