#!/bin/bash

HOSTNAME="<tablespace-db-hostname>"
PASSWORD="<tablespace-db-password>"

sudo apt-get update
sudo apt-get install -y postgresql-client

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz
chmod 777 ~ hits.tsv

psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" < create.sql
psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"
psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" < index.sql
psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" -t -c '\timing' -c "vacuum analyze hits"
psql "host=$HOSTNAME port=5432 dbname=csdb user=csuser password=$PASSWORD sslmode=require" -t -c '\timing' -c "select columnstore.database_size('csdb')"

./run.sh 2>&1 | tee log.txt

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
