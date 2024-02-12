#!/bin/bash

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
guzip hits.tsv.gz
chmod 666 hits.tsv

psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' < create.sql

psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"

# COPY 99997497
# Time: 1598808.666 ms (26:38.809)

time psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' < index.sql

# real	221m33.140s
# user	0m0.030s
# sys	  0m0.020s

psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' -t -c '\timing' -c "vacuum analyze hits"

psql 'host=<hostname> port=5432 dbname=csdb user=csuser password=<password> sslmode=require' -t -c '\timing' -c "select columnstore.database_size('csdb')"

# database_size
# ---------------
# 122870918103

sudo chmod a+x ./run.sh

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' | awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
