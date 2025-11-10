#!/bin/bash

set -eu

PGVERSION=17

# Source: https://wiki.postgresql.org/wiki/Apt
sudo apt-get update -y
sudo apt-get install -y postgresql-common -y
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

sudo apt-get update -y
sudo apt-get install -y postgresql-$PGVERSION

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

psql ${SUPABASE_CONNECTION_STRING} -c 'CREATE DATABASE test'
psql ${SUPABASE_CONNECTION_STRING} -t <create.sql

echo -n "Load time: "
command time -f '%e' ./load.sh

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
echo
