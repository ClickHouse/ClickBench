#!/bin/bash

# Ubuntu
sudo apt-get update
sudo apt-get install -y postgresql-client gzip

# Amazon Linux
# yum install nc postgresql15

rm -rf hits.tsv
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz
chmod 777 hits.tsv

rm -rf umbra-25-01-23.tar.xz umbra
wget --continue 'https://db.in.tum.de/~schmidt/umbra-2025-01-23.tar.xz'
tar -xf umbra-2025-01-23.tar.xz

rm -rf db
mkdir db

export USEDIRECTIO=1
umbra/bin/sql -createdb db/umbra.db <<<"ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'password';"

time umbra/bin/sql db/umbra.db create.sql

./run.sh 2>&1 | tee log.txt

du -bcs db/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
