#!/bin/bash

TRIES=3
QUERY_NUM=1
cat queries.sql | while read query; do
    #sync
    #echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

	echo $query > /tmp/query.sql

    echo -n "["
    for i in $(seq 1 $TRIES); do
		RES=$(datafusion-cli -f create.sql /tmp/query.sql 2>&1 | tail -n 1)
		[[ "$(echo $RES | awk '{print $5$6}')" == "Querytook" ]] && \
			echo -n "$(echo $RES | awk '{print $7}')" || \
			echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

		echo "${QUERY_NUM},${i},${RES}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done
