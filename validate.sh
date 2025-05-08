#!/bin/bash

set -o noglob
cat queries.sql | while read query; do
    echo -n "${query}..."
    RES=$(~/clickhouse client --host "z0ur79yngg.us-central1.gcp.clickhouse-staging.com" --user ${USER:=playbench} --password ${PASSWORD:=} --secure --time --format=Null --query="$query" 2>&1) 
    if [[ "$?" == "0" ]]; then
        echo "OK"
        echo $query >> valid.sql
    else
        echo "FAIL"
        echo $RES
    fi
done
set +o noglob