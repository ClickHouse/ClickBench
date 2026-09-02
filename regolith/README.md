# Regolith

[Regolith](https://github.com/sourcenetwork/regolith) is an embedded LSM-tree
key-value store written in Rust, with a synchronous API and no async runtime.
It writes SSTables, a WAL and a manifest to a local directory, which is its
only storage mode, so this entry runs it the way it is meant to be run.

Regolith has no query language: its API is `put`/`get`/`scan` over byte keys.
This entry follows the usual approach for key-value stores, and follows it the
way the [SlateDB](../slatedb) entry does, so a comparison between the two
isolates the storage engine rather than the harness. The storage layout and
query execution live in the client, [`hits-regolith`](hits-regolith/):

- **Storage**: one key-value pair per row. Key = 8-byte big-endian row index;
  value = the row in a compact positional encoding (little-endian fixed-width
  integers, varint-length-prefixed strings). Schema and row count sit under two
  metadata keys. The encoder, decoder and key layout are byte-for-byte the ones
  the SlateDB entry uses.
- **Queries**: the 43 SQL queries run unmodified through [Apache
  DataFusion](https://datafusion.apache.org/) embedded in the same binary, with
  a custom `TableProvider` whose partitions are parallel Regolith range scans
  (one contiguous key range per CPU). Projection pushdown skips the decode of
  unused columns, but every query still scans full rows out of Regolith. There
  is no columnar shortcut past the KV store.

So the numbers measure Regolith's scan path (block decode, decompression, merge
across levels) plus row decode, with DataFusion providing SQL on top. Against
`datafusion` (the same SQL engine reading Parquet directly) this isolates what
the KV storage layer costs; against `slatedb`, the two engines against each
other.

Regolith is pinned to `0.1.3`, the first release that can serve this workload.
With more than one compaction worker, 0.1.2 could hand the same input files to
two workers, which then wrote two sorted runs covering the same key range into
one level; a scan across that level stops at the first key that does not
advance, so it returns a fraction of the rows and reports success. Loading this
dataset hit it every time. Fixed in
[regolith#186](https://github.com/sourcenetwork/regolith/pull/186).

## Non-default settings

Per the fine-tuning rules, all of these are database options, not per-query
hints, and none depends on knowing the queries in advance:

- `compression = Lz4`, Regolith's default. Uncompressed, the row-oriented
  database is several times larger and the scan becomes bound on reading bytes.
- 64 KiB data blocks (default 16 KiB): every read is a range scan of whole
  blocks, so a larger block amortizes the per-block header, checksum and
  decompression call.
- `bloom_bits_per_key = 1`, the floor the options allow. No point lookup
  touches a user row, so a bloom filter would only add bytes to every SSTable
  and hashing to every compaction. Regolith rejects 0.
- `l0_compaction_trigger = 2`: keeps L0 shallow during the load, so a scan
  merges one run per populated level rather than one per L0 file.
- 1 GiB memtable and four of them, 1 GiB block cache, 64 MiB write batches per
  parquet partition: about 6 GiB of a stated budget on a 32 GiB machine, sized
  as shares of one number so the load uses the machine without risking an OOM
  kill.
- 256 MiB target SSTable size, 2 GiB L1 budget, background compactions and
  subcompactions at the CPU count.
- The WAL is off for the bulk load (`WriteOptions::disable_wal`), which ends
  with an explicit flush and a clean close. Queries open the database
  read-only.
- The load drains L0 before closing, watching the level rather than
  `compact_step`'s return value, which is false both when there is nothing to
  do and when another worker holds the files it would have picked. Rewriting
  every level instead was measured and rejected: a full `compact_range` cost
  1239 extra seconds of load and returned 10.5% on warm queries and 0.4% on
  cold, a net loss once load time is weighed at its 10% share.
- The harness binary uses jemalloc, as the SlateDB entry does: with glibc
  malloc the allocation churn of the load path grows RSS several GB beyond live
  data.

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

To validate results, the binary has a `queryp` mode that runs the same SQL
directly against the Parquet file with the same DataFusion version:
`echo '<query>' | hits-regolith/target/release/hits-regolith queryp hits.parquet create.sql`.

## Reproducing the published run

The runner, the log parser and the board renderers are not part of this entry;
they live outside the checkout. The runner renders upstream's
`cloud-init.sh.in` with the same substitutions `run-benchmark.sh` uses, so the
instance type, AMI, disk, swap and benchmark invocation match every other
entry. The parser applies the same extraction rules and completeness gate as
the `sink.parser` view in `prepare-database.sql`, and refuses a log that fails
the gate rather than writing out a plausible-looking file.
