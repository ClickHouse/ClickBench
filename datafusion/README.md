# Datafusion

DataFusion is an extensible query execution framework, written in Rust, that uses Apache Arrow as its in-memory format. For more information, please check <https://arrow.apache.org/datafusion/user-guide/introduction.html>

We use parquet file here and create an external table for it; and then do the queries.



### to generate benchmark results:

```bash
bash benchmark.sh
```



### to generate full human readable results 

1. install datafusion-cli
2. download the parquet ```wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet```
3. execute it ```datafusion-cli -f create.sh queries.sh``` or ```bash run2.sh```
