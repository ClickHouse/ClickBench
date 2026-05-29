# Jd (J Database)

[Jd](https://www.jsoftware.com/) is Jsoftware's high-performance
columnar RDBMS, written in C with a deep J integration. **Non-commercial
use is free**; a non-commercial key is auto-installed on first run.

This entry uses Jd's native `reads` query language (SQL-ish but with J
syntax) rather than translating to ANSI SQL — Jd accepts SQL keywords
in a different order (`reads <select> from <table> where <where> order
by <order>`) and uses `by` inside `reads` for `GROUP BY`. The
`queries.sql` file holds J expressions that wrap `jd 'reads …'` calls
plus J operators for things Jd's query layer doesn't ship (`LIMIT`,
`DISTINCT`).

## Install

`./install`:

1. Downloads the J 9.6 runtime zip
   ([jsoftware/jsource `build96` release](https://github.com/jsoftware/jsource/releases/tag/build96))
   to `~/j9.6` and symlinks `bin/jconsole` to `/usr/local/bin/ijconsole`
   (the J wiki recommends the `i`-prefix to avoid clashing with the
   JDK's `jconsole`).
2. Uses J's package manager (`pacman` / `jpkg`) to install the
   [`data/jd`](https://github.com/jsoftware/data_jd) addon.
3. Runs a smoke-test query so Jd auto-installs the non-commercial key.

## Load

`./load` ingests `hits.csv` via Jd's built-in CSV loader
(`csvprepare_jd_` + `csvload_jd_`). Jd writes per-column files under
`./db/`.

## Query

`./query` reads a J expression from stdin and evaluates it via
`ijconsole query.ijs`. The `query.ijs` script loads the Jd database,
times the eval, and emits the result on stdout / runtime on stderr.

## Query adaptations

The translations stay close to the SQL semantics but diverge in a few
places:

* **`LIMIT n`** isn't a `reads` keyword — we use J's `n {.` after the
  query (e.g. `10 {. jd '...'`).
* **`LIMIT n OFFSET m`** uses `n {. m }. jd '...'`.
* **`COUNT(DISTINCT col)`** uses J's `# ~.` (count of unique items)
  after pulling the column with `jd 'reads col from t'`.
* **Q29** (`REGEXP_REPLACE`) and **Q43** (`DATE_TRUNC('minute', ...)`)
  use facilities not in Jd's `reads` language; they currently return
  the literal `'null'` and the benchmark driver records them as
  missing. They could be expressed with a J-side computed column —
  contributions welcome.

`EventDate` literals (`'2013-07-01'`, etc.) in Q37–Q42 are encoded as
days-since-epoch integers (the form Jd stores `EventDate` in after the
CSV load): 2013-07-01 = day 15887, 2013-07-31 = day 15917.

## Performance notes

J / Jd is single-threaded by default. Jd's columnar layout makes
single-column scans fast; cross-column `where`-then-aggregate paths
are also vectorised in the C core. There is no daemon — each `query`
call cold-starts `ijconsole`, loads the database (mostly memory-mapped
columns), and runs.
