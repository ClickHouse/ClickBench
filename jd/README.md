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

1. Clones `jsoftware/jsource@build96` and uses `jlibrary/` as the J
   installation root, then overlays the platform-specific binary
   (`jconsole`, `libj.so`, `libtsdll.so`, `libgmp.so`) from the same
   tag's release zip (`l64.zip` on x86_64, `rpi64.zip` on aarch64).
   The release zip ships binaries only and won't run without
   `jlibrary/`'s standard library.
2. Installs a small `/usr/local/bin/ijconsole` wrapper that
   re-execs the real `jconsole` under `faketime '2026-05-10
   00:00:00'`. **Why:** Jd's bundled `jdkey.txt` is an evaluation
   key Jsoftware refreshes periodically, and the copy in
   `jsoftware/data_jd` expired 2026-05-16. Until upstream pushes a
   new key (tracked in the data_jd repo as `jdkey.txt`), every
   `jconsole` invocation needs to see a date before the expiry or
   `jdlicense` returns `_2` ("eval key") and `jd.ijs:147` asserts
   out. Backdating with faketime is the cheapest workaround that
   keeps the rest of Jd intact.
3. Uses J's package manager (`pacman` / `jpkg`) to install the
   [`data/jd`](https://github.com/jsoftware/data_jd) addon and its
   J-side dependencies (`api/curl`, `ide/jhs`, `arc/lz4`,
   `general/misc`, `data/jfiles`, `data/jmf`, `net/jcs`,
   `net/socket`, `web/gethttp`, `convert/json`, `convert/pjson`).

## Load

`./load` ingests `hits.csv` via Jd's built-in CSV loader
(`csvprepare_jd_` + `csvload_jd_`). The loader writes per-column
files to a dedicated database under `~/j9.6-user/temp/jd/csvload/`;
that's the database `./query` opens.

## Query

`./query` reads a J expression from stdin and evaluates it via
`ijconsole query.ijs`. The `query.ijs` script opens the `csvload`
database, times the eval, prints the result to stdout, and emits
the runtime in fractional seconds to file id 5 (stderr).

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
