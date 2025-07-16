#!/bin/bash

set -eu

PGVERSION=17

# Source: https://wiki.postgresql.org/wiki/Apt
sudo apt-get update -y
sudo apt-get install -y postgresql-common -y
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

sudo apt-get update -y
sudo apt-get install -y postgresql-$PGVERSION

memory=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
threads=$(nproc)
cpus=$(($threads / 2))
# Shared buffers is set to 25% of memory in AWS RDS by default. We do the same.
# https://docs.aws.amazon.com/prescriptive-guidance/latest/tuning-postgresql-parameters/shared-buffers.html
shared_buffers=$(($memory / 4))
# Effective cache size does not need to be perfect, but it should be somewhat
# close to the total memory minus what is expected to be used for queries.
# https://www.cybertec-postgresql.com/en/effective_cache_size-what-it-means-in-postgresql/
effective_cache_size=$(($memory - ($memory / 4)))
# By default, max_worker_processes is set to in postgres. We want to be able to
# use all the threads for parallel workers so we increase it. We also add a
# small buffer of 15 for any other background workers that might be created.
max_worker_processes=$(($threads + 15))
# Below we make sure to configure the rest of the parallel worker settings to
# match the number of cpu cores:
# https://www.crunchydata.com/blog/postgres-tuning-and-performance-for-analytics-data
#
# We also increase work_mem because we are doing an analytics workload to allow
# some more memory for sorting, aggregations, etc.
#
# It's necessary to increase max_wal_size to make the dataload not take very
# long. With the default value it's constantly checkpointing, and the PG logs
# warn you about that and tell you to increase max_wal_size.

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

../lib/download-tsv.sh

sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t <create.sql

echo -n "Load time: "
command time -f '%e' ./load.sh

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo du -bcs /var/lib/postgresql/$PGVERSION/main/ | grep total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
