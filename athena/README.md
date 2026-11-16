## Amazon Athena

Athena is a serverless query service: it queries data in place on S3, with
table metadata kept in the AWS Glue Data Catalog. This entry uses the shared
ClickBench driver (`../lib/benchmark-common.sh`), and every step goes through
the AWS CLI v2 — no console clicks are needed.

There are two entries over the same scripts:

* `athena` — the dataset as one 14 GB parquet file
  (`s3://clickhouse-public-datasets/hits_compatible/athena/`);
* `athena-partitioned` — the dataset as 100 parquet files
  (`s3://clickhouse-public-datasets/hits_compatible/athena_partitioned/`).
  Its scripts are symlinks to the ones here; only `ATHENA_VARIANT=partitioned`
  and `template.json` differ.

Athena does not accept a single file as a table location, only a directory,
which is why the single-file layout is a directory holding one file.

### Prerequisites

AWS credentials with access to Athena, Glue, and S3 — environment variables,
an instance profile, or SSO:

```
aws sso login --profile <profile>
export AWS_PROFILE=<profile>
```

### Running

```
./benchmark.sh > log.txt 2>&1 && ./make-result log.txt
(cd ../athena-partitioned && ./benchmark.sh > log.txt 2>&1 && ./make-result log.txt)
```

or both at once: `./run-both.sh`. The results are written to
`results/<date>/serverless.json` of each entry.

Settings (all optional):

| variable           | default                                                        |
|--------------------|----------------------------------------------------------------|
| `AWS_REGION`       | the CLI's configured region, else `us-east-1`                  |
| `ATHENA_WORKGROUP` | `primary`                                                      |
| `ATHENA_OUTPUT`    | `s3://clickbench-athena-<account>-<region>/results/`, a bucket created by `./install` with a 1-day expiration rule |

In EU regions the data is read from `clickhouse-public-datasets`
(eu-central-1), elsewhere from its us-east-1 mirror
`clickhouse-public-datasets--us-east-1`; `CLICKBENCH_DATASET_BUCKET`
overrides this.

### Script layout

| script        | role                                                              |
|---------------|-------------------------------------------------------------------|
| `env.sh`      | sourced by the others: variant, region, database, locations, `athena_run` |
| `install`     | installs the AWS CLI if missing, a venv with boto3, checks credentials, creates the result bucket |
| `start`/`stop`| no-ops (managed service, no local daemon)                         |
| `check`       | `aws athena get-work-group`                                       |
| `load`        | creates database `clickbench_<variant>` and the external table `hits` from `create.sql` |
| `query`       | runs one query from stdin; result → stdout, seconds → stderr      |
| `concurrent-worker` | one concurrent-QPS client: one boto3 client cycling through the queries |
| `athena.py`   | the boto3 client behind `query` and `concurrent-worker`           |
| `data-size`   | total size of the parquet files on S3                             |
| `make-result` | converts a log into `results/<date>/serverless.json`              |

### Notes

* The reported time of a query is Athena's own `TotalExecutionTimeInMillis`
  (queueing, planning, execution, and service processing), so the client's
  polling interval and start-up are not counted.
* Query result reuse is explicitly disabled for every query.
* "Load" only registers the external table, so the load time is a few seconds.
* There is no way to make Athena cold, so the first try is not a cold run
  (the `no-cold` tag).
* Athena charges per byte scanned. One run of an entry, including the 10-minute
  concurrent-QPS test, scans a few TB.
