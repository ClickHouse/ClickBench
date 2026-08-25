# ClickHouse (memory)

The `hits` table is a [`Memory`](https://clickhouse.com/docs/engines/table-engines/special/memory)
table created with `SETTINGS compress = true`, so the blocks live in the
server's heap, LZ4-compressed with the same default codec MergeTree writes to
disk, and are decompressed on every read.

Everything else — the ClickHouse version, the queries, the client, the
`INSERT ... SELECT * FROM file('hits_*.parquet')` load — is identical to the
[clickhouse](../clickhouse) entry, so the difference between the two entries
is the storage engine and nothing else:

- no sorting key, no primary index and no granule marks, so every query is a
  full scan of the columns it touches; the last seven queries, which filter
  on `CounterID = 62 AND EventDate >= ...`, lose the primary key lookup that
  makes them nearly free on MergeTree;
- no PREWHERE: `supportsPrewhere` is false for `Memory`, so a filter is a
  separate step above `ReadFromMemoryStorage` and every column the query
  mentions is materialized for all 100M rows before the filter runs, instead
  of being read only for the rows that passed;
- worse compression: unsorted blocks take 30.1 GB in RAM against 15.3 GB on
  disk for MergeTree, whose sorting key makes the same data compress exactly
  2x better (an uncompressed `Memory` table takes 83 GB);
- no I/O and no page cache in the read path.

A `Memory` table is not durable: nothing is written to `/var/lib/clickhouse`
and the restart that the driver performs before every cold run empties it.
`benchmark.sh` therefore sets `BENCH_DURABLE=no`, which makes the driver
re-run `./load` after each restart and charge the reload to the cold
measurement, the same contract `duckdb-memory` uses. The cold numbers are
consequently dominated by the reload, and the hot numbers are what this entry
is actually about.

The dataset needs 30 GB of RAM plus the insert's working memory, so this entry
only runs on machines with substantially more than 32 GB: on `c6a.4xlarge` and
`c8g.4xlarge` the `INSERT` dies with `MEMORY_LIMIT_EXCEEDED` against the
26.8 GiB `max_server_memory_usage` (0.9 of RAM), and the smaller machines
never had a chance. It is not part of the daily fleet for that reason; launch
it with the "Run a benchmark" workflow on a metal instance.

## What the first run showed

Against the `clickhouse` entry on the same machines (2026-08-25 versus the
2026-08-24 daily runs), summing the hot runs of the 43 queries:

| | c6a.metal | c7a.metal-48xl | c8g.metal-48xl |
| --- | --- | --- | --- |
| size, disk -> RAM | 15.3 -> 30.0 GB | 15.3 -> 29.9 GB | 15.3 -> 30.2 GB |
| load, s | 261 -> 67 | 270 -> 66 | 258 -> 67 |
| all 43 queries | 1.12x | 0.93x | 0.97x |
| 29 full-scan queries | 0.87x | 0.80x | 0.81x |
| Q21-24, `URL LIKE` | 3.57x | 1.22x | 1.31x |
| Q37-43, primary key | 2.54x | 1.79x | 2.21x |
| QPS, 10 connections | 12.3 -> 9.3 | 24.4 -> 19.6 | 26.7 -> 21.0 |

Loading is ~4x faster with nothing to sort, write or fsync, and the queries
that have to scan everything anyway are 13-20% faster in RAM — the
uncompressed volume is the same, so the same bytes are decompressed either
way, and what MergeTree spends on marks and granules across its ~25 parts is
saved. The queries that lose are the ones whose MergeTree plan skips work: the
`URL LIKE` group reads every mentioned column for all rows without PREWHERE
(`SELECT *` in Q24 is the worst case), and the `CounterID = 62` group scans
instead of seeking. Overall the two are within ~10% of each other, which is
the interesting result: the on-disk engine is not paying for being on disk.
