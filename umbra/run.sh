#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    umbra/bin/server -createSSLFiles -certFile db/umbra.cert -keyFile db/umbra.pem -address 0.0.0.0 db/umbra.db &> umbra.log &

    retry_count=0
    while [ $retry_count -lt 120 ]; do
        if nc -z localhost 5432; then
            break
        fi

        retry_count=$((retry_count+1))
        sleep 1
    done

    echo "$query";
    for i in $(seq 1 $TRIES); do
        psql -h /tmp -U postgres -t -c '\timing' -c "$query" | grep 'Time'
    done

    
    killall -9 -w server
done
