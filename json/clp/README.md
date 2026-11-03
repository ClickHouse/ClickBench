# CLP

[CLP](https://github.com/y-scope/clp) for JSON logs (the `clp-json` package), the latest release,
deployed as described in its quick start: the package's Docker Compose services, with the
documents compressed by `sbin/compress.sh`, and queried with SQL through
[Presto with the CLP connector](https://docs.yscope.com/clp/main/user-docs/guides-using-presto.html)
(`tools/deployment/presto-clp` of the same release: a Presto coordinator and a Prestissimo
(Velox) worker that reads the CLP archives directly).

## CLP and µSlope

The storage engine of `clp-json` is `clp-s`, the implementation of µSlope
(["µSlope: High Compression and Fast Search on Semi-Structured Logs"](https://www.usenix.org/system/files/osdi24-wang-rui.pdf), OSDI 2024):
the documents are parsed into a schema tree, split by schema into column-oriented tables,
and compressed into archives; the search evaluates the filters on the archives directly.
This entry is µSlope: the package's compression workers run `clp-s` compression, and the
Presto connector pushes the filters of the queries down into `clp-s` search (KQL).

There is no separate entry for the standalone `clp-s` binary: it cannot express any of the
five queries. Its search takes a KQL filter and supports only the scalar aggregations
`--count`, `--count-by-time`, `--min`, `--max` and `--unique` of the matching documents,
without grouping (its SQL grammar is a placeholder), while every JSONBench query groups by a
field. An entry with `clp-s` alone would record five nulls, and its data size is that of the
same archive format as here.

## Details

- No table definition: the `default` dataset is created by the compression, with the schema
  inferred from the documents. The queries access the fields as Presto columns, `commit` as a
  `ROW` (`"commit".collection`).
- The documents are compressed without `--timestamp-key` (none of the queries filters by
  time; with it, `time_us` would be stored as a timestamp rather than an integer).
- CLP fails the whole input file on the first invalid JSON document, so the few invalid lines
  of the dataset (documents of more than 64 KiB cut into two lines) are dropped before the
  compression (`filter-json.py`, as in `../mongodb`), into uncompressed staging files.
- The data size is the size of the archives (`var/data/archives`).
- `retains_structure` is `yes`: CLP decompresses the archives back into the original JSON
  documents (`sbin/decompress.sh`).
- The runtime of a query is the wall-clock time of its execution over Presto's HTTP protocol
  (`query`).

Settings different from the defaults:

- The Presto coordinator's memory limit per query (`query.max-memory`,
  `query.max-memory-per-node`) is 1 GB in the deployment; it is set to half of the RAM, the
  query memory that the deployment's set-up script gives to the worker. The aggregations over
  the user ids do not fit into 1 GB at the larger dataset sizes.
- The package's usage telemetry is disabled.
