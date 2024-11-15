#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync

    mysql -u admin -h $ENDPOINT -P 3306 --default-auth=mysql_native_password --database=test -vvv -e "${query}"

    # to get the most accurate 'hot' query results, wait for async compilations to finish to ensure we have a compiled plan
    while [[ $( mysql -u admin -h $ENDPOINT -P 3306 --default-auth=mysql_native_password --database=test -e 'select sum(variable_value) v from information_schema.mv_global_status where variable_name = "Inflight_async_compilations" having v != 0') ]]; do
        sleep 1
    done

    for i in $(seq 2 $TRIES); do
        mysql -u admin -h $ENDPOINT -P 3306 --default-auth=mysql_native_password --database=test -vvv -e "${query}"
    done;
done;

