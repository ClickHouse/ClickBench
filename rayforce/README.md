# Rayforce

[Rayforce](https://github.com/RayforceDB/rayforce) is a zero-dependency
columnar analytics and graph engine written in pure C (MIT). Columnar
scans and graph traversals share one operation DAG, which is optimized
and then executed as morsel-driven bytecode over 1024-row batches.
Queries are written in **Rayfall**, Rayforce's Lisp-like query language,
so `queries.sql` holds 43 Rayfall expressions (one per line) rather than
SQL.

## Install

`./install` builds from source with `make release`. Rayforce publishes an
amd64 `.deb` and prebuilt tarballs, but ClickBench also runs on aarch64
machines and the engine is dependency-free C that builds with a plain
`make` on both, so building is the only setup that covers every machine
in the matrix. `RAYFORCE_VERSION=vX.Y.Z ./install` pins a release;
unset, it takes the latest GitHub release.

## Data layout

`./load` streams `hits.csv` into a splayed on-disk table under `./hits`
with `.csv.splayed` — one file per column plus the `.sym` dictionary,
parsed in parallel from an mmap of the CSV without materializing the
table in memory. The column names come from `create.rfl`; passing an
explicit name vector also tells the reader the input has no header row,
which is the shape of the published `hits.csv`.

Types follow `../clickhouse/create.sql`: `BIGINT` → `I64`, `INTEGER` →
`I32`, `SMALLINT` → `I16`, `TIMESTAMP` → `TIMESTAMP`, `Date` → `DATE`.
Rayforce's CSV reader parses the `YYYY-MM-DD` and `YYYY-MM-DD HH:MM:SS`
forms in the file into its native date/timestamp types, so
`EventDate >= '2013-07-01'`, `extract(minute FROM EventTime)` and
`DATE_TRUNC('minute', EventTime)` all work on native values.

### Why every text column is SYM

Rayforce has two text column types: `SYM` (dictionary-encoded, one
integer index per row into a global intern table) and `STR`
(variable-length, 12 bytes inline or a per-vector byte pool). `STR` is
the type its docs recommend for high-cardinality text such as URLs, but
it does not reach ClickBench scale in the current release:

* **The pool offset is a `uint32_t`**, so a column's pool is capped at
  4 GiB (`src/io/csv.c` bails out above it). At 100M rows the `URL`,
  `Title`, `Referer` and `OriginalURL` columns hold roughly 9, 11, 8 and
  5 GB of bytes, so none of them fit in one `STR` column.
* **Opening a `STR` column validates every element** (bounds plus a
  4-byte prefix compare against the pool, `col_validate_str_region`),
  and the cost is superlinear: on a subset of this dataset a splayed
  table with five `STR` columns opened in 0.4 s at 2M rows but 199 s at
  9.6M rows. The same table with dictionary-encoded text opened in
  17 s at 9.6M rows.

Loading all TEXT / VARCHAR / CHAR columns as `SYM` sidesteps both: it
has no 4 GiB limit, and the columns become narrow integer vectors (the
9.6M-row subset is 4.4 GB with every text column dictionary-encoded,
versus 7.5 GB with those five columns as `STR`).
Dictionary encoding is what makes the dataset loadable at all here; it
also makes `GROUP BY URL` an integer group-by, while the string
operations in Q28 and Q29 pay an extra indirection per row to resolve
symbol ids back to bytes. A third reason not to go back to `STR` for
now: `take:` — i.e. every `LIMIT` — currently returns empty strings for
pool-backed values
([RayforceDB/rayforce#404](https://github.com/RayforceDB/rayforce/issues/404)).

## Server mode

Rayforce is embeddable and normally invoked as a CLI, but this entry runs
it as an IPC server (`./start` → `rayforce -p 5000 server.rfl`) because
opening the table is eager: it validates every column file and loads the
symbol dictionary before the first query. Paying that once per server
start instead of once per query process keeps it out of the reported
numbers and out of the run's wall clock. The listening socket only
accepts connections after `server.rfl` finishes, so `./check` — a
one-expression IPC round trip — is a genuine readiness probe.

`./query` sends the query text; the server evaluates
`(timeit (set rf-result <query>))`, which returns the elapsed
milliseconds from a nanosecond clock, and a second untimed round trip
pulls the result back so it can be printed. Timing therefore covers
server-side query execution only, the same convention as the other
embedded engines here (e.g. DuckDB's `.timer`).

### Cold runs

`BENCH_RESTARTABLE=yes` is required, not optional: with the server left
running, `drop_caches` cannot evict pages that a live process still has
mapped, and a "cold" query measured 0.029 s — exactly its warm time —
versus 0.44 s after a real restart. Restarting between queries makes the
cold number honest, at the price of re-reading the table on every start
(hence `BENCH_CHECK_TIMEOUT=1800`). Note the flip side: because the open
is eager, on a machine whose RAM comfortably exceeds the dataset the
first query still runs against a fully resident table.

## Query adaptations

The queries are direct Rayfall translations of the ClickBench SQL. All 43
were checked against `clickhouse-local` on a 2M-row subset of the same
CSV; the only differences are which of several equally-ranked rows a
`LIMIT` over ties returns, plus the projection differences noted below.
Points worth knowing:

* **`COUNT(*)`** is `(count hits)`; `COUNT(*)` over a filter is
  `(count (select {...}))`.
* **Ungrouped `COUNT(DISTINCT c)`** (Q5, Q6) is a whole-column reducer,
  `(count (distinct (at hits 'c)))`, and not a `select` projection: the
  projection form returns the row count instead of the distinct count
  ([RayforceDB/rayforce#405](https://github.com/RayforceDB/rayforce/issues/405)).
  Per-group `COUNT(DISTINCT c)` (Q9-Q12, Q14, Q23) is written inline as
  `(count (distinct UserID))` and lowers to Rayforce's grouped
  count-distinct kernels.
* **`HAVING`** (Q28, Q29) has no clause form: the group-by runs as an
  inner `select` and the outer one filters on the aggregate.
* **`LIMIT n OFFSET m`** (Q39-Q43) is `take: [m n]`.
* **`extract(minute FROM EventTime)`** (Q19) is `(minute EventTime)`;
  **`DATE_TRUNC('minute', EventTime)`** (Q43) is
  `(xbar EventTime 60000000000)`, i.e. truncation to whole minutes of
  the nanosecond timestamp.
* **`CASE WHEN ... END`** (Q40) is the row-wise `(if cond then else)`,
  which the query compiler lowers to the DAG's ternary select.
* **`ORDER BY` a column that is not selected** (Q25, Q27): sorting
  happens after projection, so those queries project `EventTime`
  alongside `SearchPhrase`. Same rows, same order, one extra column in
  the printed output.
* **`GROUP BY 1, URL`** (Q35): a constant is not accepted as a group
  key, and grouping by `(1, URL)` is the same partition as grouping by
  `URL`, so the constant is projected by an outer `select` instead.
* **Derived group keys** (Q36) go in the `by:` dict as
  `ip1: (- ClientIP 1)`, which the optimizer turns into a synthetic
  column rather than a materialized one. Rayforce emits the aggregate
  before the derived keys, so the result has the same rows as the SQL
  with the columns in a different order.
* **`REGEXP_REPLACE`** (Q29): Rayforce has no regex engine, so the
  host extraction `^https?://(?:www\.)?([^/]+)/.*$` is spelled out with
  the string builtins — `str-find` for `://`, `www.` and the first `/`,
  `substr` to cut, and `if` to fall back to the whole `Referer` when the pattern
  does not match (no `http`/`https` scheme at offset 0, or no `/` after
  the host). On this dataset it reproduces `REGEXP_REPLACE` exactly,
  including the fallback rows: the group keys, counts, `MIN(Referer)`
  and average lengths all match ClickHouse.
* **`MIN(URL)` / `MIN(Title)`** (Q22, Q23) work directly on `SYM`
  columns and return the lexicographic minimum, not the minimum
  dictionary index.
