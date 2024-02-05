#!/usr/bin/env bash
#set -x

PASS="${PASSWORD:-}"
CLICKHOUSE_CLIENT="/home/ubuntu/clickhouse client ${HOST:+--host ${HOST}}  ${PASSWORD:+--password ${PASS}} ${PASSWORD:+--secure} --progress 0"
TRIES=5

for i in {1..10}; do ${CLICKHOUSE_CLIENT} --query 'SELECT version();' > /dev/null && break || sleep 1; done

cat "all_queries.sql" | while read query; do
    [ -z "$HOST" ] && sync
    if [ -z "$HOST" ]; 
    	then echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; 
	else ${CLICKHOUSE_CLIENT} --query "SYSTEM DROP FILESYSTEM CACHE ON CLUSTER 'default'" > /dev/null 
    fi
    

    echo -n "["
    for i in $(seq 1 $TRIES); do
        RES=$(${CLICKHOUSE_CLIENT} --database sparse --time --format=Null --max_memory_usage=100000000000 --query="$query" 2>&1)
        [[ "$?" == "0" ]] && echo -n "${RES}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
done
