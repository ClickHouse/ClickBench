# DataFusion

[Apache DataFusion] is an extensible query execution framework, written in Rust, that uses [Apache Arrow] as its in-memory format. For more information, please check <https://arrow.apache.org/datafusion/user-guide/introduction.html>

[Apache DataFusion]: https://arrow.apache.org/datafusion/
[Apache Arrow]: https://arrow.apache.org/

We use parquet file here and create an external table for it; and then execute the queries.

## Cookbook: Generate benchmark results

The benchmark should be completed in under an hour. On-demand pricing is $0.6 per hour while spot pricing is only $0.2 to $0.3 per hour (us-east-2).

1. manually start a AWS EC2 instance
    - `c6a.4xlarge`
    - Ubuntu 24.04 or later
    - Root 500GB gp2 SSD
    - no EBS optimized
    - no instance store
1. wait for status check passed, then ssh to EC2 `ssh ubuntu@{ip}`
1. `git clone https://github.com/ClickHouse/ClickBench`
1. `cd ClickBench/datafusion`
1. `vi benchmark.sh` and modify following line to target Datafusion version

    ```bash
    git checkout 51.0.0
    ```

1. `bash benchmark.sh`
1. `./save-result.sh c6a.4xlarge`

### Know Issues

1. importing parquet by `datafusion-cli` doesn't support schema, need to add some casting in queries.sql (e.g. converting EventTime from Int to Timestamp via `to_timestamp_seconds`)
2. importing parquet by `datafusion-cli` make column name column name case-sensitive, i change all column name in queries.sql to double quoted literal (e.g. `EventTime` -> `"EventTime"`)

## Generate full human readable results (for debugging)

1. install datafusion-cli
2. download the parquet ```wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet```
3. execute it ```datafusion-cli -f create_single.sql queries.sql``` or ```bash run2.sh```
