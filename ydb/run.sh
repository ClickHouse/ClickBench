#!/bin/bash
TRIES=3
set -e
source benchmark_variables.sh

YDB_PASSWORD=password

cert_dir=$(find ydb-ansible-examples/TLS/CA/certs -maxdepth 1 -type d -not -path "." -printf "%T@ %p\n" | sort -n | tail -n 1 | cut -d' ' -f2-)

# YDB uses raw block devices, that means there is not need to drop filesystem caches
# sync
# echo 3 | sudo tee /proc/sys/vm/drop_caches

cat queries.sql | while read -r query; do
    echo -n "["

    for i in $(seq 1 $TRIES); do
        result=$(echo $YDB_PASSWORD | ydb-ansible-examples/3-nodes-mirror-3-dc/files/ydb -e grpcs://$host1$host_suffix:2135 -d /Root/database --ca-file $cert_dir/ca.crt --user root yql -s "$query" --stats basic 2>/dev/null)

        # Extracting total_duration_us value
        if [[ "$result" =~ total_duration_us:[[:space:]]*([0-9]+) ]]; then
            duration_us=${BASH_REMATCH[1]}
            # Convert microseconds to seconds
            duration_sec=$(awk "BEGIN {printf \"%.6f\", $duration_us/1000000}")
            echo -n "$duration_sec"

            if [ $i -ne $(($TRIES)) ]; then
                echo -n ","
            fi
        else
            exit -1
        fi
    done
    echo "],"
done
