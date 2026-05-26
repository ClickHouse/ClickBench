# LocustDB

LocustDB (https://github.com/cswinter/LocustDB) is an experimental column-oriented database written in Rust. The first ClickBench attempt
left only a "this system does not work at all" note because the post-load `SELECT * FROM default LIMIT 1` panicked with:

```
thread '<unnamed>' panicked at 'index out of bounds: the len is 65536 but the index is 65536', src/stringpack.rs:91:15
```

The panic is triggered by an unchecked indexed read inside the
`StringPackerIterator` once a string-packed partition is fully consumed,
which the upstream code still hasn't fixed. The default
`--partition-size` is `65536`, exactly the boundary the iterator
mismanages — so we set `--partition-size 16384` in `./load` to shrink
each block well under that ceiling and dodge the path.

Other things worth knowing for anyone reproducing this:

- The `enable_rocksdb` cargo feature referenced in older notes no longer
  exists; LocustDB's storage path is native and the binary is just
  `target/release/repl`.
- There is no headless "load and exit" command. We invoke `repl --load
  hits.csv --db-path db --table hits` with stdin redirected from
  `/dev/null` — rustyline returns `Err(Eof)` immediately after the load
  finishes and the process exits cleanly.
- Query execution goes through LocustDB's HTTP server (`repl --server`)
  via `POST /query` with a JSON body. LocustDB's response includes
  per-query stats but not a wall-clock timing, so the `./query` script
  measures the round-trip itself.
- Several ClickBench queries use SQL that LocustDB doesn't implement
  (`REGEXP_REPLACE`, `DATE_TRUNC`, `extract(...)`, `CASE WHEN`,
  ordering by string columns, etc.). The harness records `null` for
  each unsupported query rather than aborting the run.
- `COUNT(DISTINCT …)` in LocustDB is approximate by design.

If LocustDB's load or scan still crashes on the modern code path, the
benchmark will report load + null query times and surface the panic in
the run log, instead of silently failing as it did in the original
attempt.

## Newer panic during load (2026-05-17)

On c6a.4xlarge the load thread panics partway through ingest with a
column-length consistency violation inside `mem_store`:

```
thread '<unnamed>' panicked at src/mem_store/partition.rs:56:13:
Expected column "" to have length 1146880 but got 1114112
(column: ColumnHandle { key: ColumnLocator { table: "hits", id: 1323, column: "" },
  name: "", size_bytes: 151369, ... })
```

Worth noting:

- The shortfall (1146880 − 1114112 = 32768) is exactly `2 × --partition-size`,
  so one column is missing two partitions' worth of rows when the
  invariant check fires. The `--partition-size 16384` workaround for the
  older `stringpack.rs` panic doesn't help here — it appears to have
  just relocated the failure from the scan path to the load path.
- `column: ""` with `id: 1323` (well past hits' ~105 user columns) is a
  LocustDB-internal synthetic column (string-dict shard or similar),
  not one of ours, so it can't be worked around by reshaping the CSV.
- Only the load thread panics; the `repl` process keeps running, so
  the harness sits on the load step until cloud-init's outer timeout
  (currently 36000 s) kills the instance. The result row therefore
  shows up in the sink as `Total time: 36016` with no per-query
  timings, rather than as a clean per-query failure.

Until upstream fixes this, LocustDB runs on the full hits dataset will
not produce a result file.
