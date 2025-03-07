#!/bin/bash

set -eux

PGVERSION=17

sudo apt-get update
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh

sudo apt-get update
sudo apt-get upgrade
sudo apt-get install -y postgresql-$PGVERSION

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
chmod 777 hits.tsv

sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t < create.sql

# Load data: wrap TRUNCATE and \copy FREEZE in a single transaction
# If we dont' do this, Postgres will throw an error:
#     "ERROR: cannot perform COPY FREEZE because the table was not created or truncated in the current subtransaction"
# (i.e. Postgres requires that the table be either created or truncated in the current subtransaction)
sudo -u postgres psql test <<'EOF'
BEGIN;
TRUNCATE TABLE hits;
\copy hits FROM 'hits.tsv' with freeze;
COMMIT;
EOF

sudo -u postgres psql test -t -c 'VACUUM ANALYZE hits'

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

./run.sh 2>&1 | tee log.txt

sudo du -bcs /var/lib/postgresql/$PGVERSION/main/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
