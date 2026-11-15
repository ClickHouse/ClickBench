## MotherDuck (data lake)

MotherDuck querying the ClickBench data **in place on S3**, in the spirit of
`clickhouse-datalake` and `duckdb-datalake`. Nothing is loaded into MotherDuck
storage: `./load` creates a `clickbench_datalake` database holding only a VIEW
over the public `hits.parquet` (plus the `toDateTime` macro the queries use),
and every query runs on the remote Duckling, which reads S3 directly
(`EXPLAIN` shows `READ_PARQUET (R)`).

For the native-storage variant (data CTAS'ed into MotherDuck), see
`../motherduck`.

### Running

```
motherduck_token=<TOKEN> ./benchmark.sh            # at the current Duckling size
motherduck_token=<TOKEN> ./run-size.sh jumbo       # resize if needed, run, write results/<date>/jumbo.json
motherduck_token=<TOKEN> ./run-all-sizes.sh        # mega jumbo standard pulse, largest first
```

`run-all-sizes.sh` is `../motherduck/run-all-sizes.sh` pointed at this
directory: it resizes the Duckling before every size (with the settle wait),
runs the benchmark into `motherduck-datalake-<size>.log`, and writes
`results/<date>/<size>.json`. Same size arguments and env (`INCLUDE_GIGA=1`,
`RESTORE_SIZE`) as there.

`run-size.sh` reuses the motherduck entry's helpers:
`../motherduck/set-instance-size` (only called when the live size differs) and
`../motherduck/make-result`, which labels the result `Motherduck: <size>`
because the client EC2 type is meaningless for a remote service.

### Notes

* **Bucket region.** The S3 read happens on the Duckling, not on the client.
  `load` uses `../lib/dataset-bucket.sh`, which picks the bucket copy by the
  client's EC2 region; run the client in the MotherDuck organization's region
  (us-east-1 for US orgs) or set `CLICKBENCH_DATASET_BUCKET` explicitly.
* **No cold run.** There is no way to drop the Duckling's caches from the
  client, so like `../motherduck` this entry is tagged `no-cold`; the first try
  of each query is whatever state the Duckling is in.
* **Load time / data size** are the view creation time and the fixed size of
  the parquet file, as for the other data-lake entries.
* Driver settings (`BENCH_RESTARTABLE=no`, `BENCH_DURABLE=yes`) and their
  rationale match `../motherduck`.
* **Concurrent QPS** uses `../motherduck/concurrent-worker` with
  `MOTHERDUCK_DATABASE=clickbench_datalake`: each of the
  `BENCH_CONCURRENT_CONNECTIONS` (default 10) workers keeps one `md:`
  connection open for the whole window, so the result measures the Duckling,
  not client-side connection setup.
