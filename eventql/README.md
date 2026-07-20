# EventQL

[EventQL](https://github.com/eventql/eventql) was a distributed
columnar database aimed at large-scale event analytics. Upstream
stopped in 2017 and the source no longer compiles on modern gcc
(upstream issue [#367](https://github.com/eventql/eventql/issues/367)):
the bundled ZooKeeper 3.4.8 C client has incomplete types that 2017's
toolchains warned about but 2026's reject. The closest known-good
toolchain is Ubuntu 14.04 + clang + libc++ (the only configuration
upstream Travis ever tested), but Ubuntu 14.04 and 16.04 are no longer
served by `archive.ubuntu.com` or `old-releases.ubuntu.com` in a state
that can complete an `apt-get install` — a source build inside a fresh
Docker container is no longer reachable end-to-end.

The resurrection path here uses what every other working EventQL
deployment in the wild uses: the **prebuilt 0.4.1 binary** from
upstream's GitHub release, run inside an Ubuntu 18.04 container so its
2017-era libstdc++ / glibc dependencies are satisfied. The binary's
ELF marker says "for GNU/Linux 2.6.32", so any glibc since Ubuntu
14.04 will load it; 18.04 is just the most convenient still-pullable
baseline.

The other half of the problem was data loading. Upstream issue
[#365](https://github.com/eventql/eventql/issues/365) noted there was
no bulk-CSV path. `loader.py` reads the TSV on stdin and drives 32
concurrent posters with 1000 rows per batch against
`POST /api/v1/tables/insert` — the JSON-array shape upstream's own
mysql2evql uses. Every value is stringified; EventQL's insert handler
parses strings into the table schema's declared type server-side.

## Sharp edges this benchmark works around

What I had to fix to make a single-node setup actually serve queries:

- **Trash subdir.** `evqld --standalone` does not auto-create its
  `trash/` subdirectory under `--datadir`. Until that directory
  exists, the garbage-collection thread errors every 30 s and — more
  importantly — blocks the metadata service so inserts and SELECTs
  fail with "no metadata server responded" while CREATE TABLE still
  superficially succeeds. The Dockerfile pre-creates `trash/` and
  `data/`, and `./start` re-creates them on the host bind-mount side
  (since the mount overlays the image's directories).
- **`Title` is reserved.** EventQL's SQL parser treats `Title` as the
  `T_TITLE` keyword. The only escape that works is backticks
  (`` `Title` ``); double quotes are taken as string literals. No
  other ClickBench hits column collides.
- **Type set is narrower than the docs say.** The shipped v0.4.1
  binary accepts only `UINT32`, `UINT64`, `STRING`, `DATETIME`,
  `DOUBLE`, `FLOAT`, `BOOL`. `INT32` / `INT64` / `BIGINT` / `TEXT` /
  `VARCHAR` / `BYTES` are all rejected as "invalid type". All hits
  values are non-negative, so SMALLINT/INTEGER/BIGINT map to
  UINT32/UINT64; TEXT/VARCHAR/CHAR map to STRING; TIMESTAMP/DATE map
  to DATETIME.
- **PRIMARY KEY is mandatory.** The first column must be
  STRING/UINT64/DATETIME (it doubles as the partition key). We use
  `(EventTime, WatchID)`.
- **Database is implicit.** The documented
  `POST /api/v1/create_database` endpoint returns 404 on this build;
  the `clickbench` database is materialised on first CREATE TABLE
  through `POST /api/v1/sql`.

## Query compatibility

A lot of ClickBench's queries lean on SQL that EventQL doesn't
implement, and our `./query` script exits non-zero on a returned
`{"error": …}` so the harness records `null` for that try:

- `SUM` works; **`AVG` does not** — "symbol not found: AVG".
- **`LIKE` planning is broken** — "don't know how to encode this
  QueryTreeNode" (queries 21–24).
- **`COUNT(DISTINCT …)`** is rejected by the parser, not even falling
  back to the approximate count the docs hint at (queries 5, 6, 9,
  11–14, 23).
- **`REGEXP_REPLACE`** is not in the function table (query 29).
- **`<>`** is rejected by the parser ("ltExpr needs second argument");
  `!=` works.
- **`DATE_TRUNC`** works.
- **`EXTRACT(minute FROM …)`** is not tested; would surprise me if it
  worked given the rest.

Expect most of the 43 queries to come back null. The benchmark still
reports the load wall-clock, the on-disk data size, and whichever
queries do parse and execute.

## Operational notes

- The on-disk data directory is bind-mounted from
  `/var/lib/clickbench-eventql` on the host, so `./data-size` can `du`
  it directly without `docker exec`.
- `./start` is idempotent: it skips relaunching if the container is
  already up. `./stop` is also idempotent.
- The HTTP listener binds 0.0.0.0:9175 inside the container; the host
  reaches it via `--network host`.

This was validated end-to-end against the v0.4.1 binary running inside
the Ubuntu 18.04 image: CREATE TABLE + INSERT + SELECT all return
correct results on a 1000-row synthetic sample. Whether the full 100M
hits load lands under the 10 h benchmark timeout depends on raw insert
throughput on the target VM — `loader.py` reports rate every 30 s so
operators can spot a stall.
