#!/bin/bash

export HOST="twolunc123.eu-west-1.aws.clickhouse-staging.com"
export PASSWORD="KNjGEvqsFiPd"

TRIES=5
QUERY_NUM=1
cat queries.sql | while read query; do
    # [ -z "$HOST" ] && sync
    # [ -z "$HOST" ] && echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    # sync
    # echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    # clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --query="SYSTEM DROP FILESYSTEM CACHE" --progress 0 2>&1
    # clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --query="SYSTEM DROP MARK CACHE" --progress 0 2>&1

    [ ! -z "$HOST" ] && clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --query="SYSTEM DROP FILESYSTEM CACHE ON CLUSTER 'default'" --progress 0 2>&1
    [ ! -z "$HOST" ] && clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --query="SYSTEM DROP MARK CACHE ON CLUSTER 'default'" --progress 0 2>&1

    echo -n "["
    for i in $(seq 1 $TRIES); do
        # RES=$(clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null --allow_asynchronous_read_from_io_pool_for_merge_tree=1 --max_streams_for_merge_tree_reading=128 --allow_prefetched_read_pool_for_remote_filesystem=1 --filesystem_prefetch_max_memory_usage=128073741824 --query="$query" --progress 0 2>&1 ||:)
        # --allow_prefetched_read_pool_for_remote_filesystem=1 --filesystem_prefetch_max_memory_usage=0 --filesystem_prefetch_step_marks=40 --filesystem_prefetches_limit=32 --max_read_buffer_size=10000000 \
        RES=$(clickhouse-client --host "${HOST:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format=Null \
                --query="$query" --progress 0 2>&1 ||:)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
