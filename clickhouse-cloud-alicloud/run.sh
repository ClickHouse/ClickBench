#!/bin/bash


TRIES=3
QUERY_NUM=1
cat queries.sql | while read -r query; do
    echo -n "["
    for i in $(seq 1 $TRIES); do
      CACHE_PARAMS=''
      if [[ "$i" == 1 ]];then
        CACHE_PARAMS=',enable_filesystem_cache=0'
      fi
      (clickhouse-client --host "$FDQN" --user "$USER" --password "$PASSWORD" --time --format=Null --query="$query settings log_queries=1$CACHE_PARAMS;" --progress 0 2>&1 |
          grep -o -E '^[0-9]+\.[0-9]+$' || echo -n "null") | tr -d '\n'
 
      [[ "$i" != $TRIES ]] && echo -n ", "
    done
    echo "],"
 
    QUERY_NUM=$((QUERY_NUM + 1))
done