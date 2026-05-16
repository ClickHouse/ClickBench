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
