#!/bin/bash
set -e -x

# Idempotent (-p), so re-running across BENCH_RESTARTABLE iterations
# doesn't fail on "File exists" once the dirs are set up.
docker exec hdfs-namenode hdfs dfs -mkdir -p /user/clickhouse
docker exec hdfs-namenode hdfs dfs -chown clickhouse /user/clickhouse
docker exec hdfs-namenode hdfs dfs -chmod -R 775 /user/clickhouse
