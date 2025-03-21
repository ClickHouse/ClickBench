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

sudo -u postgres psql -c "CREATE DATABASE test"
sudo -u postgres psql test -c "CREATE EXTENSION timescaledb WITH VERSION '2.17.2';"

# Import the data
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
sudo chmod og+rX ~
chmod 777 hits.tsv

sudo -u postgres psql test < create.sql
sudo -u postgres psql test -c "SELECT create_hypertable('hits', 'eventtime', chunk_time_interval => interval '3 day', create_default_indexes => false)"
sudo -u postgres psql test -c "ALTER TABLE hits SET (timescaledb.compress, timescaledb.compress_segmentby = '', timescaledb.compress_orderby = 'counterid, userid, eventtime')"
sudo -u postgres psql test -c "ALTER DATABASE test SET timescaledb.enable_chunk_skipping to ON;"
sudo -u postgres psql -c "ALTER DATABASE test SET work_mem TO '1GB';"
sudo -u postgres psql -c "ALTER DATABASE test SET min_parallel_table_scan_size TO '0';"
sudo -u postgres psql test -c "SELECT enable_chunk_skipping('hits', 'counterid');"

sudo -u postgres psql test -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"

# See https://github.com/timescale/timescaledb/issues/4473#issuecomment-1167095245
# https://docs.timescale.com/timescaledb/latest/how-to-guides/compression/manually-compress-chunks/#compress-chunks-manually
# TimescaleDB benchmark wihout compression is available in timescaledb no columnstore directory

sudo -u postgres psql test -c "SELECT compress_chunk(i, if_not_compressed => true) FROM show_chunks('hits') i"
sudo -u postgres psql test -t -c '\timing' -c "vacuum freeze analyze hits;"

#datasize
sudo -u postgres psql test -c "\t" -c "SELECT hypertable_size('hits');"

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
