## MotherDuck (DuckLake)

MotherDuck querying a **MotherDuck-managed DuckLake** copy of the ClickBench
data. `./load` creates an empty DuckLake database
(`CREATE DATABASE clickbench_ducklake (TYPE DUCKLAKE)`), creates `hits` from
`create.sql`, and INSERTs from the public `hits.parquet` on S3. The INSERT writes
DuckLake's own parquet data files into MotherDuck-managed storage; the source
files are copied, not adopted in place.

Related entries: `../motherduck` (native MotherDuck storage) and
`../motherduck-datalake` (a view over the S3 parquet, nothing loaded).

### Running

```
motherduck_token=<TOKEN> ./benchmark.sh            # at the current Duckling size
motherduck_token=<TOKEN> ./run-size.sh jumbo       # resize if needed, run, write results/<date>/jumbo.json
```

`run-size.sh` reuses `../motherduck/set-instance-size` (only called when the
live size differs) and `../motherduck/make-result`, which labels the result
`Motherduck: <size>`.

### Notes

* **Bucket region.** The load reads S3 on the Duckling, not on the client.
  `load` uses `../lib/dataset-bucket.sh`, which picks the bucket copy by the
  client's EC2 region; run the client in the MotherDuck organization's region
  or set `CLICKBENCH_DATASET_BUCKET` explicitly.
* **Data size** is the total size of the DuckLake data files backing `hits`,
  from `ducklake_list_files()`.
* `create.sql` and `queries.sql` are the same as `../motherduck` (typed
  TIMESTAMP/DATE columns). Driver settings (`BENCH_RESTARTABLE=no`,
  `BENCH_DURABLE=yes`, `BENCH_CONCURRENT_DURATION=0`) and the `no-cold` tag
  match `../motherduck`.
