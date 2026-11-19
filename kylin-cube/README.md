# Apache Kylin 5.0.2-GA with a model built by Kylin

Apache Kylin is a multidimensional OLAP engine: queries are answered from
pre-built indexes ("cuboids") of a model, and only queries no index can answer
are pushed down to Spark. The `kylin` entry measures pushdown only, without a
model. This entry measures Kylin with its indexes.

The setup is the same as in `kylin` (the standalone all-in-one Docker image
`apachekylin/apache-kylin-standalone:5.0.2-GA`, `-m 10G`, the official
`hits.parquet` registered as a Hive table and loaded into the project
`clickbench`). Then `./load` lets Kylin design the model itself
(`build-model.py`):

1. The project is switched to the semi-automatic (recommendation) mode.
2. The 43 benchmark queries are sent to Kylin's SQL-based model suggestion
   API (`POST /api/models/model_suggestion`), which creates an online model
   with the aggregate indexes, table indexes and computed columns that answer
   them, and one full-range segment (the model has no partition column).
3. The indexes are built into that segment (`POST /api/models/{model}/indexes`),
   and `./load` waits for the build job.

The index build is included in the load time. The log of `./load` lists the
suggested indexes and the queries that Kylin did not model (`error_sqls`):
those are pushed down at query time, as in `kylin`.

Because the indexes are derived from the benchmark queries, which is
pre-aggregation, the entry is marked as tuned. It is added for comparison as a
system of the multidimensional OLAP kind (see "Preaggregation" in the main
README).

The Spark resources are left at the image's defaults, as in `kylin`.
Kylin sizes the build jobs automatically (`kylin.spark-conf.auto-prior=true`)
within the limits of the YARN inside the container
(`yarn.scheduler.maximum-allocation-vcores=1`, `maximum-allocation-mb=4096`).

The data size is the source file plus the project's working directory on HDFS
(`/kylin/<metadata>/clickbench`, which holds the indexes, dictionaries and
snapshots); the source file is kept because pushdown queries read it.

Q19, Q29 and Q40 repeat the expressions in `GROUP BY` instead of referencing
select-list aliases, which Kylin's Calcite rejects with the default
conformance (see `kylin/README.md`).

`./query` logs to stderr whether a query was answered by an index (model,
layout and index type) or pushed down; the benchmark driver discards it on
success, so it is useful for manual runs only.

The query result cache (`kylin.query.cache-enabled`, on by default) is
disabled in `./start`. Answers from indexes go into it, so with the cache the
hot runs took 0.01-0.02 s regardless of the query (first run, 2026-11-19).
The `kylin` entry keeps the default, because it caches no pushdown results
(`kylin.query.pushdown.cache-enabled=false`).

First run on `c6a.4xlarge` (2026-11-19, with the cache): Kylin modeled all
queries except Q29 (it stayed pushdown). The build took most of the
17594 s load, and the indexes made the data size 103 GB, against the
14.8 GB source file. Q24 and Q29 failed; `./query` now prints Kylin's
`exceptionMessage` on failure.

The image is amd64 only, so there are no results for Graviton machines.
