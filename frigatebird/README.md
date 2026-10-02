# Frigatebird

[Frigatebird](https://github.com/Frigatebird-db/frigatebird) is an embedded
columnar SQL database written in Rust. It implements a push-based Volcano
execution model with morsel-driven parallelism, late materialization,
vectorized filtering, dictionary encoding, and an io_uring + O_DIRECT
storage layer with WAL durability.

## Notes on this benchmark

* Frigatebird only accepts `INSERT ... VALUES` for ingestion — no `COPY`,
  no Parquet/CSV reader. `./load` therefore streams `hits.parquet` through
  `parquet_to_inserts.py` (pyarrow) into the Frigatebird REPL as batched
  `INSERT INTO hits (...) VALUES (...), (...), ...` statements.
* Frigatebird's type system collapses all integer widths (`SMALLINT`,
  `INT`, `BIGINT`) to `i64` and `DATE` to `TIMESTAMP`, so `create.sql`
  uses `BIGINT` for every integer column and `TIMESTAMP` for `EventDate`.
* `CREATE TABLE` requires an `ORDER BY` clause — we use
  `(CounterID, EventDate, UserID, EventTime, WatchID)`, matching the
  primary key used by the other ClickBench entries.
* The CLI has no query timer, so `./query` measures runtime with bash
  built-in `time` (`TIMEFORMAT='%R'`).
* Frigatebird's INSERT planner rejects unary-minus literals
  (`UnaryOp { Minus, Number }`), so `parquet_to_inserts.py` emits negative
  integers as quoted strings (e.g. `'-1216690514'`); the column-type
  coercion path parses them back to `i64`.
* Several queries use SQL features Frigatebird does not implement
  (`EXTRACT`, `REGEXP_REPLACE`, `LENGTH`/`STRLEN`, `CASE`, scalar
  arithmetic on big projections, etc.); those queries fail at parse or
  plan time and the corresponding entries in `results/*.json` will be
  `null`.
* In smoke testing on a 10k-row slice of `hits.parquet`, simple scans
  (`SELECT COUNT(*)`, `SELECT WatchID … LIMIT 3`, filtered counts) either
  hung indefinitely or panicked with
  `failed to decompress page payload: string is not valid utf8` — likely
  triggered by the non-UTF-8 bytes in the hits dataset's text columns.
  The benchmark recipe is wired up regardless so the upstream behaviour
  on the full dataset is reproducible; expect many or all queries to
  show up as `null` until Frigatebird stabilises ingest/scan paths for
  non-UTF-8 string data.
