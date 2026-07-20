# kdb (KDB-X Community Edition)

[KDB-X](https://code.kx.com/kdb-x/) is KX's column-oriented array database
powered by the `q` language. The **Community Edition** is free for
personal and commercial use.

This entry uses KDB-X's built-in ANSI SQL interface (`.s.e`) so the
standard ClickBench queries can be run with minimal adaptation.

## Results cannot be published

The KX Community Edition License Agreement contains a DeWitt clause:

> You will not disclose any benchmark, test or performance information or
> any report which contains a competitive analysis regarding the Software
> to any third party except as explicitly authorized in advance by us in
> writing.

For that reason this directory **does not include a `results/` folder**
and ships a `.gitignore` that excludes it, so timings produced by anyone
running these scripts cannot be committed by accident. Running the
benchmark for personal or internal use is permitted by the license; only
disclosing the resulting numbers without KX's written authorization is
not.

See the top-level [README](../README.md) — "If The Results Cannot Be
Published" — for the project's general handling of this case.

## Manual setup

The installer is gated behind a Developer Center sign-up. Before running
`benchmark.sh`, register at

> https://developer.kx.com/products/kdb-x/install

and copy the base64-encoded `kc.lic` license from the install page.
Export it in the shell that will run the benchmark:

```bash
export KDB_B64LIC='...'         # base64-encoded kc.lic, required
export KDB_AUTH_TOKEN='...'     # OAuth bearer (optional; the installer
                                # download URL is currently public)
```

The `install` script then runs the official installer non-interactively
and symlinks the `q` binary into `/usr/local/bin`. The KDB-X installer
sometimes drops the SQL module silently; `install` fetches `sql.k_`
directly as a fallback so `query` can rely on `.s.e`.

## Data layout

`load` reads `hits.parquet` via the `kx.pq` module and writes a splayed
kdb table under `./hits/`. KDB-X Community Edition is capped at 16 GB
RAM (see
[license usage restrictions](https://code.kx.com/insights/1.18/licensing/usage-restrictions.html)),
which is below the materialized size of the 100 M-row hits dataset, so
`load.q` streams the parquet one row group at a time instead of holding
the whole table in memory. Date and timestamp columns (epoch-encoded in
the parquet file) are converted to native kdb types during the load so
the SQL `WHERE EventDate >= '2013-07-01'`,
`extract(minute FROM EventTime)`, and `DATE_TRUNC('minute', EventTime)`
forms all work.

## Query adaptations

The queries are taken verbatim from the upstream ClickBench set with one
syntactic change: `STRLEN(...)` is rewritten to `LENGTH(...)` because
KDB-X SQL exposes the scalar string length as `length`, not `strlen`
(see
[SQL functions reference](https://code.kx.com/insights/1.18/core/sql/functions.html)).

When run against the full hits dataset, the KDB-X SQL translator rejects
or runs out of resources on a handful of queries. Locally observed
failures include:

* Q19 — alias `m` from `extract(minute FROM EventTime) AS m` is rejected
  when reused in `GROUP BY UserID, m, SearchPhrase`.
* Q28, Q33, Q35 — heavy aggregations that hit the CE 16 GB RAM cap.
* Q29 — `REGEXP_REPLACE` is not implemented.
* Q40, Q41 — `CASE WHEN ... AS Src` and `IN (-1, 6)` (negative literal)
  produce translator errors.
* A few high-cardinality `ORDER BY` / `GROUP BY` queries exceed a
  practical wall-clock budget on a single-threaded CE process.

Queries that fail mid-benchmark are recorded as `null` in the result
JSON, matching how other systems with the same gaps are reported.

## Threading

`query` invokes `q` with `-s 0` (single-threaded) so the timings are
directly comparable to other single-threaded entries. KDB-X CE allows up
to 4 secondary threads via `-s N`; a multi-threaded run can be
contributed as a separate `kdb-tuned` directory per the ClickBench
contribution guidelines.
