#!/bin/bash

TRIES=3

queryNum=1
cat queries.sql | while read query; do
    for i in $(seq 1 $TRIES); do
	    echo "Running query $queryNum: $query"
        /opt/presto-cli --server 127.0.0.1:8080 --user clickbench_runner --catalog "hive" --schema "clickbench_parquet" --session offset_clause_enabled=true --execute "${query}"
        execution_time=$(/opt/presto-cli --server 127.0.0.1:8080 --user clickbench_manager --execute "SELECT date_diff('millisecond',started,\"end\") FROM system.runtime.queries WHERE user='clickbench_runner' ORDER BY created DESC LIMIT 1" | tr -d '"') && echo "Execution time: ${execution_time}ms"
    done
    ((queryNum++))
done
