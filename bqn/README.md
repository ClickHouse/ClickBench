# BQN

[BQN](https://mlochbaum.github.io/BQN/) is a modern array language in
the APL/J/k family, with a static type system and a small, regular
syntax. This entry uses [CBQN](https://github.com/dzaima/CBQN), the
production C implementation.

BQN is not a database — there's no SQL, no parquet reader, no query
optimizer. The 43 ClickBench queries have been hand-translated into BQN
in [queries.bqn](queries.bqn); the SQL forms are kept in
[queries.sql](queries.sql) purely as reference.

## Data layout

`load` runs [prep.py](prep.py), a Python preprocessor that reads
`hits.parquet` (via pyarrow) and writes one binary file per column
under `./cols/`:

* numeric columns → `<col>.f64`, raw little-endian f64
* string columns → `<col>.str` (concatenated UTF-8 bytes) +
  `<col>.off` (little-endian f64 byte offsets, `n+1` entries)

BQN reads these in `util.bqn` via `•FBytes` plus `8‿64 •bit._cast`. The
queries themselves are pure BQN; Python only shows up at load time
because BQN doesn't ship a parquet reader.

## Query dispatch

`benchmark.sh` overrides `BENCH_QUERIES_FILE=queries.idx`, a 43-line
file containing `1`..`43`. For each line the driver pipes the integer
into `./query`, which calls the matching `Qn` function in
`queries.bqn`. Reference SQL is still in `queries.sql` for documentation
but not consumed by the driver.

## Query adaptations

The translations stay close to the SQL semantics but diverge in two
places:

* **Q24** (`SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY
  EventTime LIMIT 10`) reconstructing 100+ columns just to discard them
  isn't useful in BQN. The translation returns the 10 row indices in
  EventTime order — the same work the driver would otherwise serialise
  out to the client.
* **Q29** (`REGEXP_REPLACE`) — BQN has no regex engine. The hostname is
  approximated by stripping `http://` / `https://` / `www.` prefixes and
  taking everything before the next `/`. This covers the actual data in
  the ClickBench Referer column.

The `EventDate` literals (`'2013-07-01'`, etc.) in Q37–Q43 are encoded
as days-since-epoch integers because `prep.py` stores EventDate that
way: 2013-07-01 = day 15887, 2013-07-31 = day 15917, 2013-07-14 = day
15900, 2013-07-15 = day 15901.

## Performance notes

CBQN is single-threaded. The 100 M-row dataset materialises to roughly
80 GB across the per-column files, which keeps the heavy queries
(`COUNT DISTINCT`, large `GROUP BY`) bound on memory bandwidth rather
than parsing or planning.

`query` invokes `BQN` with default flags. There is no daemon to keep
warm between queries, so cold runs pay process startup plus the cost of
memory-mapping the column files the query touches.
