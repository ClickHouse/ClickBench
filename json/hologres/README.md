# Hologres

[Hologres](https://www.alibabacloud.com/product/hologres) is a real-time data warehouse of
Alibaba Cloud, compatible with PostgreSQL. It is a managed service only, so it cannot be
installed on the benchmark machine and the results in `results/` were submitted by
Alibaba Cloud in https://github.com/ClickHouse/JSONBench/pull/87 (measured on 2025-10-09,
Hologres r4.0, a 32 CU instance). They were not reproduced.

The scripts run the benchmark with the usual driver from a client machine that can reach
the instance. They need the connection in the environment and are not part of the
unattended EC2 runs.

## Procedure

1. Create an Alibaba Cloud account. Alibaba Cloud offered coupons for reproducing the
   results (ask in the pull request above, giving the account UID).
2. Create a Hologres instance, see the
   [Hologres test plan](https://www.alibabacloud.com/help/en/hologres/user-guide/test-plan)
   for how to buy one. The submitted results used:
   - Region `China (Beijing)`, zone `Zone L` (new versions are released there first);
   - specification "Compute Group Type", 2 gateway nodes;
   - 32 CU of reserved computing resources in the initial virtual warehouse (the "32 CU"
     of the results), serverless computing enabled;
   - storage redundancy `LRS`;
   - a new VPC and vSwitch in `Beijing Zone L`, shared with the client machine below.
3. Create a client ECS instance in the same VPC and zone, e.g. `ecs.c9i.4xlarge`
   (16 vCPU, 32 GiB, not performance-critical) with a 2 TiB `PL3` system disk, Alibaba
   Cloud Linux 3 or Ubuntu 24.04, with a public IPv4 address.
4. Create a user of the instance (instance details, "Account Management",
   "Create Custom User", "Superuser"), or use an AccessKey ID and secret. Take the host
   and port of the VPC endpoint from the instance details
   (`hgxxx-cn-beijing-vpc.hologres.aliyuncs.com:xxxx`).
5. On the client:

   ```bash
   git clone https://github.com/ClickHouse/ClickBench.git
   cd ClickBench/json/hologres
   export PG_USER=... PG_PASSWORD=... PG_HOSTNAME=... PG_PORT=...
   ./benchmark.sh 1      # or 10, 100, 1000
   ```

   `result.json` is the result; save it as
   `results/hologres-32cu_bluesky_<size>m.json`.

## Notes

- `load` creates the database `jsonbench` (dropping it first) with the result cache
  disabled (`hg_experimental_enable_result_cache = off`), creates the table from
  `ddl.sql` and loads every file with `\copy`, after removing `\u0000` escapes (rejected by
  `JSONB`) and joining the documents that a raw newline splits over two lines. It ends with
  `VACUUM` and `ANALYZE`, as the PostgreSQL entry does, and prints `SHOW ALL` to the log.
- `ddl.sql` stores the documents in one `JSONB` column with the columnar `JSONB` storage
  (`enable_columnar_type`), with dictionary encoding and bitmap indexes on its paths, and
  a clustering key and a distribution key on generated columns computed from the
  documents (`kind`, `commit.operation`, `commit.collection`, `did`). Indexes are allowed
  by the JSONBench rules.
- The runtimes are measured by `psql` (`\timing`), on the client.
- The caches of the service cannot be dropped, so the first run of a query is not cold
  (tag `no-cold`).
- Differences from the scripts of the pull request: the PR also ran
  `hologres.hg_full_compact_table` after loading; it is not run any more, as a reviewer
  asked for no commands beyond those of the other entries, and the author agreed that it
  has no significant impact. The submitted results were measured with it.
