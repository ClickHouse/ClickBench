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
- worse compression: unsorted blocks give about 27 GB in RAM against 15 GB on
  disk for MergeTree, whose sorting key makes the same data compress ~1.8x
  better (an uncompressed `Memory` table takes 83 GB);
- no I/O and no page cache in the read path.

A `Memory` table is not durable: nothing is written to `/var/lib/clickhouse`
and the restart that the driver performs before every cold run empties it.
`benchmark.sh` therefore sets `BENCH_DURABLE=no`, which makes the driver
re-run `./load` after each restart and charge the reload to the cold
measurement, the same contract `duckdb-memory` uses. The cold numbers are
consequently dominated by the reload, and the hot numbers are what this entry
is actually about.

The dataset needs ~27 GB of RAM plus the insert's working memory, so this
entry only runs on machines with substantially more than 32 GB. It is not
part of the daily fleet for that reason; launch it with the "Run a benchmark"
workflow on a metal instance.
