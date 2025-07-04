#!/bin/bash

# Install

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y gnupg postgresql-common apt-transport-https lsb-release wget
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
sudo bash -c 'echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" > /etc/apt/sources.list.d/timescaledb.list'
wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | sudo apt-key add -
sudo apt-get update
sudo apt install -y timescaledb-2-postgresql-17 postgresql-client-17
sudo timescaledb-tune -yes
sudo systemctl restart postgresql

sudo -u postgres psql -c "CREATE DATABASE nocolumnstore"
sudo -u postgres psql nocolumnstore -c "CREATE EXTENSION timescaledb WITH VERSION '2.17.2';"

sudo apt-get install -y axel pigz
axel --quiet --num-connections=32 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz
sudo chmod og+rX ~
chmod 777 hits.tsv

#import
sudo -u postgres psql nocolumnstore < create.sql
sudo -u postgres psql nocolumnstore -c "SELECT create_hypertable('hits', 'eventtime', chunk_time_interval => interval '3 day')"
sudo -u postgres psql nocolumnstore -c "CREATE INDEX ix_counterid ON hits (counterid)"
sudo -u postgres psql -c "ALTER DATABASE nocolumnstore SET work_mem TO '1GB';"
sudo -u postgres psql -c "ALTER DATABASE nocolumnstore SET min_parallel_table_scan_size TO '0';"

sudo -u postgres psql nocolumnstore -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"
sudo -u postgres psql nocolumnstore -t -c '\timing' -c "vacuum freeze analyze hits;"

#datasize
sudo -u postgres psql nocolumnstore -c "\t" -c "SELECT hypertable_size('hits');"

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
