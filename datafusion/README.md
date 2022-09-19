# Datafusion

DataFusion is an extensible query execution framework, written in Rust, that uses Apache Arrow as its in-memory format. For more information, please check <https://arrow.apache.org/datafusion/user-guide/introduction.html>

We use parquet file here and create an external table for it; and then do the queries.


### To solve

q32 (line 33 in queries.sql) out of memory in my 32GB memory vm, it output null now since it's killed


### to generate benchmark results:

```bash
bash benchmark.sh
```


### Know Issues:

1. importing parquet by `datafusion-cli` doesn't support schema, need to add some casting in quries.sql (e.g. converting EventTime from Int to Timestamp via `to_timestamp_seconds`)
2. importing parquet by `datafusion-cli` make column name column name case-sensitive, i change all column name in quries.sql to double quoted literal (e.g. `EventTime` -> `"EventTime"`)
3. `comparing binary with utf-8` and `group by binary` don't work in mac, if you run these quries in mac, you'll get some errors for quries contain binary format apache/arrow-datafusion#3050


### to generate full human readable results (for debugging)

1. install datafusion-cli
2. download the parquet ```wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet```
3. execute it ```datafusion-cli -f create.sh queries.sh``` or ```bash run2.sh```
