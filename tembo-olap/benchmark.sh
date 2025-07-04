#!/bin/bash

HOSTNAME="<hostname>"
PASSWORD="<password>"

sudo apt-get update
sudo apt-get install -y postgresql-client

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz
chmod 777 ~ hits.tsv

psql postgresql://postgres:$PASSWORD@$HOSTNAME:5432 -t -c 'CREATE DATABASE test'
psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" < create.sql
psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"
psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" < index.sql
psql "host=$HOSTNAME port=5432 dbname=test user=postgres password=$PASSWORD sslmode=require" -t -c '\timing' -c "select pg_total_relation_size('hits');"

./run.sh "${HOSTNAME}" "${PASSWORD}" 2>&1 | tee log.txt

cat log.txt |
grep -oP 'Time: \d+\.\d+ ms' |
sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
awk '{
    if (i % 3 == 0) {
        printf "[";
    }
    printf $1 / 1000;
    if (i % 3 != 2) {
        printf ",";
    } else {
        print "],";
    }
    ++i;
}'
