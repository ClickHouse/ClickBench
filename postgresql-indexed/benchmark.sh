#!/bin/bash

set -eux

PGVERSION=17

sudo apt-get update
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh

sudo apt-get update
sudo apt-get upgrade
sudo apt-get install -y postgresql-common postgresql-$PGVERSION

memory=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
threads=$(nproc)
cpus=$(($threads / 2))
shared_buffers=$(($memory / 4))
effective_cache_size=$(($memory - ($memory / 4)))
max_worker_processes=$(($threads + 15))

sudo tee /etc/postgresql/$PGVERSION/main/conf.d/clickbench.conf <<EOF
shared_buffers=${shared_buffers}kB
max_worker_processes=${max_worker_processes}
max_parallel_workers=${threads}
max_parallel_maintenance_workers=${cpus}
max_parallel_workers_per_gather=${cpus}
max_wal_size=32GB
work_mem=64MB
effective_cache_size = ${effective_cache_size}kB
EOF

sudo systemctl restart postgresql@$PGVERSION-main

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t <create.sql

time ./load.sh

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

./run.sh 2>&1 | tee log.txt

sudo du -bcs /var/lib/postgresql/$PGVERSION/main/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
