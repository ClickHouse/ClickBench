# Velox

Single (1 file) Parquet dataset, queried in place.

[Velox] is a C++ vectorised execution engine. It is a library, not a database:
it has no SQL parser, no query optimizer and no catalog of its own, so it can't
be pointed at a dataset by itself. [Axiom] — also from Meta — supplies exactly
those missing pieces (PrestoSQL parser → logical plan → cost-based optimizer →
multi-fragment Velox plan → local runner) and ships them as a command line
tool, `axiom_sql`, which is what this entry benchmarks. Velox comes in as a git
submodule of Axiom and does all of the execution.

ClickBench already covers Velox as an accelerator under Spark — see
[`spark-velox/`](../spark-velox/) and [`spark-gluten/`](../spark-gluten/). This
entry runs Velox without a JVM in the loop.

[Velox]: https://velox-lib.io/
[Axiom]: https://github.com/facebookincubator/axiom

## Run

```
./benchmark.sh
```

`./install` builds Axiom, Velox and Velox's source dependencies (boost, folly,
fbthrift, arrow, ...) from source — there are no release binaries — so it
dominates the setup time and needs a machine with enough memory to compile
Velox. The job count is capped at one thread per 5 GB of RAM and a swap file is
added if there is none, because Velox's Presto function registration
translation units peak at about 4 GB each.

## Notes

- The Parquet file is queried in place through Axiom's local Hive connector,
  which treats every subdirectory of `--data_path` as a table — hence
  `data/hits/hits.parquet`. `./load` doesn't rewrite the data; it runs
  `axiom_hive_import`, which derives the schema (`.schema`) and per-column
  statistics (`.stats`) from the Parquet footer, both of which the connector
  requires.
- The reported time is the CLI's own `Total` from `--print_timing`, i.e.
  parsing plus optimization plus execution, excluding process startup (about a
  second, which would otherwise dominate the fast queries). This matches what
  the other embedded-CLI entries (`datafusion/`, `duckdb/`) report.
- `./query` passes `--num_workers 1 --num_drivers $(nproc)`. The CLI defaults to
  4 in-process "workers" of 4 drivers each, which simulates distributed
  execution: every stage boundary goes through the shuffle/exchange path, and
  even at the same total driver count that costs 10-50x on a single machine
  (Q23: 0.7s with one worker, 37s with four). One worker with one driver per
  vCPU is single-node execution at full parallelism, which is what every other
  single-node engine in the benchmark does by default.
- `axiom_sql` exits 0 even when a statement fails, so `./query` treats a
  `Query failed:` line on stderr as the failure signal.
- `--data_path` must be absolute. A relative path reaches Velox's file system
  registry, which only matches absolute paths, and the resulting error aborts
  the process from a worker thread.

## Known issues

- The Parquet file stores `EventTime` as Unix epoch seconds (`BIGINT`) and
  `EventDate` as a day count from 1970-01-01 (`UINT16`). Axiom's Hive connector
  has no views, so the conversions to the canonical ClickBench types are
  inlined in `queries.sql` (`from_unixtime(EventTime)` in Q19, Q43,
  `date_add('day', ..., DATE '1970-01-01')` in Q7) rather than hidden behind a
  view as in [`presto/`](../presto/).
- A filter on `EventDate` segfaults the scan. It is the dataset's only column
  with an unsigned Parquet type, and it appears in the filter of Q37-Q43, so
  two things work around the crash:
  1. `./load` widens the column from `SMALLINT` (Velox's mapping of `UINT16`)
     to `INTEGER` in `.schema`/`.stats`. `INTEGER` is also the faithful mapping
     of an unsigned 16-bit type and what [`presto/create.sql`](../presto/create.sql)
     declares.
  2. Q37-Q43 compare `EventDate` against the day counts directly
     (`EventDate >= 15887 AND EventDate <= 15917` for July 2013) instead of
     `date_add('day', EventDate, DATE '1970-01-01') >= DATE '2013-07-01'`,
     which still crashes even with the widened type, because the expression is
     evaluated inside the scan. This is the same shape used by
     [`firebolt-parquet/`](../firebolt-parquet/), [`drill/`](../drill/) and
     [`octosql/`](../octosql/); it selects exactly the same rows (cross-checked
     against `clickhouse local` on the same file), and only changes Q41's
     output, which prints `EventDate` as the day count rather than a date. Q7
     keeps `date_add` because there the conversion is applied to the aggregate
     result, not to a filtered column.
