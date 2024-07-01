#!/bin/bash

TRIES=3
QUERY_NUM=0
touch result.csv
truncate -s0 result.csv
export MYSQL_PWD=$password

cat queries.sql | while read -r query; do
    echo -n "query${QUERY_NUM}," | tee -a result.csv
    for i in $(seq 1 $TRIES); do
        RES=$(mysql -vvv -h $Endpoint -uadmin -P9030 -D hits -e "${query}" | perl -nle 'print $1 if /\((\d+\.\d+)+ sec\)/' ||:)

        echo -n "${RES}" | tee -a result.csv
        [[ "$i" != $TRIES ]] && echo -n "," | tee -a result.csv
    done
    echo "" | tee -a result.csv

    QUERY_NUM=$((QUERY_NUM + 1))
done;
