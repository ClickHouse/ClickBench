# DataFusion

Single (1 file) Parquet dataset

[Apache DataFusion] is an extensible query execution framework, written in Rust, that uses [Apache Arrow] as its in-memory format.

[Apache DataFusion]: https://datafusion.apache.org/
[Apache Arrow]: https://arrow.apache.org/

## Cookbook: Generate benchmark results

The benchmark should be completed in under an hour. On-demand pricing is $0.6 per hour while spot pricing is only $0.2 to $0.3 per hour (us-east-2).

1. Manually start an AWS EC2 instance. The following environments are included in this directory:

   | Instance Type |           OS            |        Disk        | Arch  |
   | :-----------: | :---------------------: | :----------------: | :---: |
   | `c6a.xlarge`  | `Ubuntu 24.04` or later | Root 500GB gp2 SSD | AMD64 |
   | `c6a.2xlarge` |                         |                    | AMD64 |
   | `c6a.4xlarge` |                         |                    | AMD64 |
   | `c8g.4xlarge` |                         |                    | ARM64 |

All with no EBS optimization and no instance store.

2. Wait for the status checks to pass, then ssh to EC2: `ssh ubuntu@{ip}`
3. `git clone https://github.com/ClickHouse/ClickBench`
4. `cd ClickBench/datafusion`
5. `vi benchmark.sh` and modify the following line to target the DataFusion version

    ```bash
    git checkout 47.0.0
    ```

6. `bash benchmark.sh`

You can update/preview the results by running:
```
./make-json.sh <machine-name> # Example. ./make-json.sh c6a.xlarge
```

### Known Issues

1. DataFusion follows the SQL standard with case-sensitive identifiers, so all column names in `queries.sql` use double-quoted literals (e.g. `EventTime` -> `"EventTime"`).

## Generate full human-readable results (for debugging)

1. Install/build `datafusion-cli`.

2. Download the parquet file:

```
wget --continue https://datasets.clickhouse.com/hits_compatible/hits.parquet
```

3. Run the queries:

```
datafusion-cli -f create.sql -f queries.sql
```

Or use the runner script:
```
PATH="$(pwd)/arrow-datafusion/target/release:$PATH" ./run.sh
```
