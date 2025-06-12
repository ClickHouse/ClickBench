#!/bin/bash

TRIES=3
rm result.txt 2>/dev/null
cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    # Oxla seems to cache major parts of the dataset without a documented way to clear the cache between the runs.
    # It seems fairer to restart the database between the runs.
    docker restart oxlacontainer
    sleep 30

    echo "$query";
    results=""
    if [[ "$query" == "SELECT NULL;" ]]; then
        results+="[null,null,null]"
    else
        results+="["
    for i in $(seq 1 $TRIES); do
            time=$(PGPASSWORD=oxla psql -h localhost -U oxla -t -c '\timing' -c "$query" | grep 'Time' | perl -nle 'm/Time: ([^ ]*) ms/; print $1 / 1000')
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
