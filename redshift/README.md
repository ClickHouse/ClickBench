## Amazon Redshift

Every step is scripted with the AWS CLI v2 and uses the shared ClickBench driver
(`../lib/benchmark-common.sh`). Setup and load go through the Redshift Data API
(`aws redshift-data`); the queries run over a native connection
(`redshift_connector`), because a Data API round trip costs seconds of client
overhead, which would swamp the startup and concurrent-QPS measurements.

There are two entries over the same scripts:

* `redshift` — a provisioned cluster (node type × number of nodes);
* `redshift-serverless` — a Serverless workgroup (base capacity in RPUs).
  Its scripts are symlinks to the ones here; only `REDSHIFT_MODE=serverless`
  and `template.json` differ.

### Prerequisites

AWS credentials allowed to manage Redshift / Redshift Serverless, the Data API,
and IAM roles — environment variables, an instance profile, or SSO:

```
aws sso login --profile <profile>
export AWS_PROFILE=<profile>
```

The cluster and the workgroup are created in the default VPC of the region and
are not publicly accessible, so the benchmark client must be an EC2 instance in
that VPC. `./provision` allows port 5439 on the cluster's security group from the
client instance's security groups (found from the instance metadata, or set
`REDSHIFT_CLIENT_SG`), and stores the managed admin password in
`.redshift-conn-<name>` (mode 600, not committed; removed by `./deprovision`).

### Running

```
./run-all.sh                                    # every ra3/rg node type at 1..4 nodes (2..4 for multi-node-only types)
./run-all.sh ra3.xlplus:4 rg.4xlarge:2          # <node type>:<nodes> ...
../redshift-serverless/run-all.sh               # 128 RPU (the default base capacity)
../redshift-serverless/run-all.sh 32 128 512    # <RPU> ...
```

For each configuration, `run-all.sh` creates the cluster (`./provision`), runs
the benchmark into `log-<configuration>.txt`, writes
`results/<date>/<nodes>x.<node type>.json` (or `serverless.json` for 128 RPU,
`<rpu>rpu.json` otherwise), and deletes the cluster (`./deprovision`; set
`KEEP_CLUSTER=1` to keep it).

To run the steps by hand:

```
export REDSHIFT_NODE_TYPE=ra3.4xlarge REDSHIFT_NODES=4   # or REDSHIFT_MODE=serverless REDSHIFT_RPU=128
./provision
./benchmark.sh > log.txt 2>&1
./make-result log.txt
./deprovision
```

Configuration (all optional):

| variable             | default                                           |
|----------------------|---------------------------------------------------|
| `REDSHIFT_MODE`      | `provisioned` (`serverless` in `redshift-serverless`) |
| `REDSHIFT_NODE_TYPE` | `ra3.xlplus`                                      |
| `REDSHIFT_NODES`     | `4`                                               |
| `REDSHIFT_RPU`       | `128`                                             |
| `AWS_REGION`         | the CLI's configured region, else `us-east-1`     |

### Script layout

| script          | role                                                            |
|-----------------|-----------------------------------------------------------------|
| `env.sh`        | sourced by the others: names, Data API target, `redshift_run`   |
| `install`       | installs the AWS CLI if missing, a venv with `redshift_connector`, checks credentials |
| `provision`     | creates the IAM role for COPY (`clickbench-redshift-s3`) and the cluster / namespace + workgroup, waits until available, opens port 5439 to the client, writes the connection file |
| `deprovision`   | deletes the cluster / workgroup + namespace (no final snapshot) |
| `start`/`stop`  | no-ops                                                          |
| `check`         | `SELECT 1` over a native connection                             |
| `load`          | `create.sql`, then `COPY` of `hits.csv.gz` from S3, then `ANALYZE` |
| `query`         | runs one query from stdin; result → stdout, seconds → stderr    |
| `data-size`     | size of `hits` from `svv_table_info`                            |
| `concurrent-worker` | one concurrent-QPS client, keeping one native connection open |
| `rs.py`         | the native client behind `query`, `check`, `concurrent-worker`  |
| `make-result`   | converts a log into a results JSON                              |
| `run-all.sh`    | provision → benchmark → result → deprovision, per configuration |

### Notes

* Each query runs in a new session with
  `SET enable_result_cache_for_session TO off`. The reported time is the
  client's wall-clock of execute + fetch, like psql's `\timing` used for the
  earlier results; it includes query compilation.
* Redshift prefers `VARCHAR(MAX)` to `TEXT`, and `UserID` is `NUMERIC(38, 0)`
  rather than `BIGINT`.
* The data is loaded from `hits.csv.gz`, a single gzip file, so the load is
  not parallel. Outside the EU it is read from the us-east-1 mirror of the
  dataset bucket.
* There is no way to make the cluster cold from the client, so the first try
  is not a cold run (the `no-cold` tag).
