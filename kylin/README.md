# Apache Kylin 5.0.2-GA

Standalone all-in-one Docker image (`apachekylin/apache-kylin-standalone:5.0.2-GA`),
bundling HDFS, YARN, Zookeeper, Hive, Spark `3.3.0-kylin-5.2.2`, and Gluten
`1.3.0-kylin-250110` (a native ClickHouse-based execution engine Kylin
layers on top of Spark). No cube is built. Every query below is a raw
pushdown query against the loaded `CLICKBENCH.HITS` table, so this does
not measure Kylin's core value proposition (pre-aggregated cubes).

Kylin 4.x is marked `retired` upstream; `5.0.2-GA` is the Docker Hub
image tag marked "Recommended for users" (no `5.0.3`/`5.0.4` standalone
image exists). The container is not restarted between query tries
(`BENCH_RESTARTABLE=no`), so this is tagged `no-cold`. Load time was
`421.406s`.

## Memory: `-m 10G`, the vendor default

Docker Hub's `5.0.2-GA` example specifies `-m 10G`; the quickstart
guide's `-m 8G` example is for the older `5.0-beta` tag, not this one.
Left at the vendor default. Also tested `install`/`start` only (no data
load) on `t3a.small` (2 GiB, fails its own readiness poll from swap
pressure, not an OOM kill) and `c6a.large` (4 GiB, succeeds).
`c6a.xlarge`, `c6a.4xlarge`, `c6a.metal`, and `c7a.metal-48xl` are
untested.

## Canary config: two keys set, likely no-ops per source

`./start` sets `kylin.canary.sparder-context-canary-enabled=false` and
`kylin.canary.sqlcontext-enabled=false`, then restarts Kylin once during
initial setup. In 5.0.2's source, `sparder-context-canary-enabled`
matches no config key anywhere; `sqlcontext-enabled` is read by
`KapConfig.getSparkCanaryEnable()`, which already defaults to `false`,
and gates whether `SparkContextCanary` starts (`SparderConfiguration.init()`),
unless an earlier `spark.local=true` check short-circuits that method
first, in which case the gate is never reached at all. Which path
actually runs in this container wasn't checked at runtime, so setting
these two keys to `false` is likely redundant rather than confirmed
inert; they're kept rather than removed.

## No Parquet rewrite needed

This build's Spark reads the official `hits.parquet`'s `EventDate`
column (Parquet `INT32`/`UINT_16`) without any rewrite, confirmed by a
separate `SELECT COUNT(*), MIN(EventDate), MAX(EventDate)` returning
`99,997,497` rows and the correct `2013-07-02`..`2013-07-31` range.
`./load` copies the file into HDFS unchanged, so `Data size` equals the
source file's byte length.

## Query result cache

Lookup stays on (`kylin.query.cache-enabled` defaults `true`, and this
`query` script doesn't force pushdown). The pushdown success-store path
defaults off (`kylin.query.pushdown.cache-enabled=false`), so no
successful pushdown result is ever cached here. The `ResourceLimitExceededException`
failure-cache path (which bypasses `kylin.query.exception-cache-enabled`)
is never thrown anywhere in 5.0.2's non-test source, so it doesn't
apply to this build's Gluten OOM failures; the ordinary exception cache
(`kylin.query.exception-cache-enabled`) also defaults off. Spark/Gluten's
own internal caching wasn't examined.

## Load row-count check

A post-run `COUNT(*) FROM clickbench.hits` returned `99997497` (exact
match), checked after the benchmark, not during it.

## Known failures (cube-less pushdown, Kylin 5.0.2-GA)

38 of 43 queries completed on all 3 tries. 5 recorded as `null`:

- **Q9, Q10**: Gluten aborts with `Memory limit exceeded ... maximum: 1.00 GiB`
  on a grouped `COUNT(DISTINCT UserID)` with no `WHERE` filter. Other
  `COUNT(DISTINCT)` queries succeed (Q5 unfiltered/ungrouped;
  Q11/Q12/Q14/Q23 filtered before grouping); the distinguishing factor
  wasn't isolated.
- **Q19, Q29, Q40**: Calcite rejects a `SELECT`-list alias (`m`/`k`/`Src`,
  none submitted uppercase or quoted) referenced in `GROUP BY`
  (`Column 'M'/'K'/'SRC' not found`), consistent with case-folding
  during resolution. This is a validation-time failure before Gluten or Spark
  runs. Q19's submitted `extract(minute FROM EventTime) AS m` is
  rewritten by Kylin to `MINUTE(EventTime) AS m` before the alias fails,
  so the error SQL differs from the submitted SQL.

`query` treats non-200 HTTP and in-band `isException:true` (HTTP 200)
as failures; `isPartial` isn't inspected.

## OFFSET

Q39/41/42/43 contain `OFFSET` and complete; Q40 also contains it but
fails on the alias issue first. Spark itself only gained `OFFSET`
support in 3.4.0 ([SPARK-28330](https://issues.apache.org/jira/browse/SPARK-28330));
this build's Spark is `3.3.0-kylin-5.2.2`, and how Kylin accepts it
despite that wasn't determined. Completion doesn't confirm the skipped
rows were correct (no independent check against a known-correct offset).

## Concurrent-QPS

10 connections, 600s: `0.058` QPS / `0.167` error ratio. Per
`bench_concurrent_qps` (`qps=ok/600`, `error_ratio=err/(ok+err)`,
`%.3f`-rounded), 35/7 is the only pair matching both. All 7 traced by
traceId: 3 match the sequential failures above; 4 are queries that
passed sequentially but failed only under concurrency with
`QueryInterruptChecker: ... Interrupted at the stage of collecting
result`; trigger not isolated.

## amd64 only

`5.0.2-GA`'s Docker Hub manifest lists amd64 only; `./install` fails
outright on arm64 hosts (`c8g.4xlarge`, `c8g.metal-48xl`).

## `./start` idempotency caveat

`./start` skips the canary-key block whenever the container already
exists, assuming prior setup completed. If an earlier readiness
timeout left the container existing-but-unconfigured, a later `./start`
would skip the block without having applied it. Whether this run hit
that path isn't verifiable from the committed files (the harness
discards `./start`'s stdout).
