#!/bin/bash

TRIES=3
rm result.txt 2>/dev/null
cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches 1>/dev/null

    echo "$query";
    results=""
    if [[ "$query" == "SELECT NULL;" ]]; then
    	results+="[null,null,null]"
    else
    	results+="["
	for i in $(seq 1 $TRIES); do
            time=$(psql -h localhost -t -c '\timing' -c "$query" | grep 'Time' | perl -nle 'm/Time: ([^ ]*) ms/; print $1 / 1000')
            echo "$time s"
            results+="$time,"
        done
        results=${results::-1}
        results+="]"
    fi
    echo "$results," >> result.txt
done
result=$(cat result.txt)
result=${result::-1}
echo "$result"
rm result.txt 2>/dev/null