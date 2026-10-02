# SlateDB

[SlateDB](https://slatedb.io/) is an embedded LSM-tree key-value store, written
in Rust, that keeps all of its state (SSTs, WAL, manifests) in an object store.
In this benchmark the object store is the local filesystem
(`object_store::LocalFileSystem`), which is SlateDB's standard single-node setup
and keeps the entry comparable to the other locally-run systems.

SlateDB has no query language — its API is `put`/`get`/`scan` over byte keys —
so this entry follows the usual approach for key-value stores: the storage
layout and query execution are implemented by the client, in
[`hits-slatedb`](hits-slatedb/):

- **Storage**: one key-value pair per row. Key = 8-byte big-endian row index;
  value = the row in a compact positional encoding (little-endian fixed-width
  integers, varint-length-prefixed strings). The schema and row count are kept
  under two metadata keys.
- **Queries**: the 43 SQL queries run unmodified through [Apache
  DataFusion](https://datafusion.apache.org/) embedded in the same binary, with
  a custom `TableProvider` whose partitions are parallel SlateDB range scans
  (one contiguous key range per CPU). Projection pushdown skips the decode of
  unused columns, but every query still pays for scanning the full rows out of
  SlateDB — there is no columnar shortcut past the KV store.

So the numbers here measure SlateDB's scan path (SST decode, block fetch from
the object store, merge across sorted runs) plus row decode, with DataFusion
providing SQL on top. The comparison against `datafusion` (same SQL engine
reading Parquet directly) isolates what the KV storage layer costs.

Non-default settings, per the fine-tuning rules:

- `compression_codec = zstd` and 64 KiB SST blocks: without compression the
  row-oriented database is ~90 GB; SST block compression is the standard
  production option for scan-heavy data.
- `wal_enabled = false` during the bulk load (with an explicit flush at the
  end): the WAL would double the load I/O for no durability benefit since the
  load ends with a flush + clean close. Queries open the database with a
  read-only `DbReader`.
- The harness binary uses jemalloc: with glibc malloc, the allocation churn of
  the load path fragments the heap and RSS grows several GB beyond live data,
  OOMing the smaller machines.
- The load waits for the embedded compactor to drain its queue, deletes the
  checkpoints left behind by compaction workers, and runs one GC pass before
  exiting. Without this the database reports ~4x its live size: closing
  mid-compaction pins the GC's low watermark, leftover checkpoints pin old
  manifests and every SST they reference, and the GC never deletes objects
  younger than 5 minutes.

SlateDB is pinned to v0.15.0 plus 17 commits (rev `d0c3d63`) because v0.15.0's
embedded compactor intermittently panics during large bulk loads
("compaction source view not found in L0") and takes the database down;
the fix ([slatedb#2002]) is merged upstream but not yet in a crates.io release.

[slatedb#2002]: https://github.com/slatedb/slatedb/pull/2002

The concurrent-QPS test is skipped: each query forks a fresh full-machine
process with no shared server (see issue #946).

## Manual run

```
wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet
./install
./load
echo 'SELECT COUNT(*) FROM hits;' | ./query
```

Or the full benchmark on a fresh VM: `bash benchmark.sh`.

For validating results, the binary also has a `queryp` mode that runs the same
SQL directly against the Parquet file with the same DataFusion version:
`echo '<query>' | hits-slatedb/target/release/hits-slatedb queryp hits.parquet create.sql`.
