#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# sets up PG14, configs, and build deps on ubuntu 22.04
sudo ./install.sh

# download hits.tsv if we dont already have it
if [ ! -e hits.tsv ]; then
    wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
    gzip -d hits.tsv.gz
fi

# ensure postgres user can access hits.tsv
chmod a+rX . hits.tsv

# set up db, user, table; load data.
sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t < create.sql
sudo -u postgres psql test -t -c 'TRUNCATE hits'
sudo -u postgres psql test -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"

# COPY 99997497
# Time: 1320024.670 ms (22:00.025)

# run test
./run.sh 2>&1 | tee log.txt

# disk usage
sudo du -bcs /var/lib/postgresql/14/main/

# 18979994590

# parse results for json file
./parse.sh < log.txt
