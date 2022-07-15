#!/bin/bash

export ENDPOINT="..."
export MYSQL_PWD="..."

mysql -h$ENDPOINT -uadmin --default-auth=mysql_native_password -P 3306 -e "create database test"
mysql -h$ENDPOINT -uadmin --default-auth=mysql_native_password -P 3306 --database=test -e "$(cat create.sql)"
mysql -h$ENDPOINT -uadmin --default-auth=mysql_native_password -P 3306 --database=test -e "create pipeline h as load data s3 'clickhouse-public-datasets/hits_compatible/hits.tsv.gz' config '{\"region\":\"us-east-1\"}' into table hits;"
time mysql -h$ENDPOINT -uadmin --default-auth=mysql_native_password -P 3306 --database=test -e "start pipeline h foreground"

./run_on_cloud.sh 2>&1 | tee log.txt

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2) { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

