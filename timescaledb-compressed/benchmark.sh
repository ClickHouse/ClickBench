#!/bin/bash

# Install
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y gnupg postgresql-common apt-transport-https lsb-release wget
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo bash -c 'echo "deb https://packagecloud.io/timescale/timescaledb/ubuntu/ $(lsb_release -c -s) main" > /etc/apt/sources.list.d/timescaledb.list'
wget --quiet -O - https://packagecloud.io/timescale/timescaledb/gpgkey | sudo apt-key add -
sudo apt-get update
sudo apt-get install -y timescaledb-2-postgresql-14
sudo bash -c "echo \"shared_preload_libraries = 'timescaledb'\" >> /etc/postgresql/14/main/postgresql.conf"
sudo systemctl restart postgresql

sudo -u postgres psql -c "CREATE DATABASE test"
sudo -u postgres psql test -c "CREATE EXTENSION IF NOT EXISTS timescaledb"

# Import the data

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
sudo chmod og+rX ~
chmod 777 hits.tsv

sudo -u postgres psql test < create.sql
sudo -u postgres psql test -c "SELECT create_hypertable('hits', 'eventtime')"
sudo -u postgres psql test -c "CREATE INDEX ix_counterid ON hits (counterid)"
sudo -u postgres psql test -c "ALTER TABLE hits SET (timescaledb.compress, timescaledb.compress_orderby = 'counterid, eventdate, userid, eventtime')"
sudo -u postgres psql test -c "SELECT add_compression_policy('hits', INTERVAL '1s')"

sudo -u postgres psql test -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'"

# 1619875.288 ms (26:59.875)

# See https://github.com/timescale/timescaledb/issues/4473#issuecomment-1167095245
# https://docs.timescale.com/timescaledb/latest/how-to-guides/compression/manually-compress-chunks/#compress-chunks-manually
# TimescaleDB benchmark wihout compression is available in timescaledb directory

time sudo -u postgres psql test -c "SELECT compress_chunk(i, if_not_compressed => true) FROM show_chunks('hits') i"

# 49m45.120s

./run.sh 2>&1 | tee log.txt

sudo du -bcs /var/lib/postgresql/14/main/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
