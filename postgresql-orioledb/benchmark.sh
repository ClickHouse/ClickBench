#!/bin/bash

# digest: sha256:3304142dbe8de8d5bbaa0e398cca58683ed603add4524c3582debf9c119994f1
VERSION=beta12-pg17
CONTAINER_NAME=orioledb-clickbench

echo "Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y docker.io pigz postgresql-client

# Using Docker due to pending patches in upstream PostgreSQL, see https://web.archive.org/web/20250722125912/https://www.orioledb.com/docs/usage/getting-started#start-postgresql
echo "Starting OrioleDB Docker container with name $CONTAINER_NAME. Using tag $VERSION..."
# Increase shared memory size, because Docker default will hit the limit ("ERROR:  could not resize shared memory segment")
MEM_SIZE=$(grep MemTotal /proc/meminfo | awk '{print $2}')
SHM_SIZE=$(echo "$MEM_SIZE/2/1024" | bc)
mkdir -p /tmp/data
sudo docker run --name $CONTAINER_NAME -v /tmp/data:/tmp/data --shm-size="$SHM_SIZE"m -p 5432:5432 -e POSTGRES_HOST_AUTH_METHOD=trust -d orioledb/orioledb:$VERSION

# Similar (but not identical) to PostgreSQL configuration
echo "Updating configuration"
THREADS=$(nproc)
CPUS=$(($THREADS / 2))

# Since we are only using OrioleDB tables, set to 1/4 of RAM and keep default value for shared buffers
# See https://www.orioledb.com/docs/usage/configuration#orioledbmain_buffers
MAIN_BUFFERS=$(($MEM_SIZE / 4))
EFFECTIVE_CACHE_SIZE=$(($MEM_SIZE - ($MEM_SIZE / 4)))
MAX_WORKER_PROCESSES=$(($THREADS + 15))

envsubst <<EOF | sudo docker exec -i $CONTAINER_NAME sh -c 'tee -a /etc/postgresql/postgresql.conf'
orioledb.main_buffers=${MAIN_BUFFERS}kB
max_worker_processes=${MAX_WORKER_PROCESSES}
max_parallel_workers=${THREADS}
max_parallel_maintenance_workers=${CPUS}
max_parallel_workers_per_gather=${CPUS}
max_wal_size=32GB
work_mem=64MB
effective_cache_size=${EFFECTIVE_CACHE_SIZE}kB
EOF

sudo docker restart $CONTAINER_NAME

(sudo docker logs -f $CONTAINER_NAME) &> "$CONTAINER_NAME.log" &
while ! tail -n 1 "$CONTAINER_NAME.log" | grep -q 'database system is ready to accept connections'; do
  echo "OrioleDB is not running yet. Checking again in 1 second..."
  sleep 1
done

echo "Downloading dataset..."
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz' -O /tmp/data/hits.tsv.gz
pigz -d -f /tmp/data/hits.tsv.gz

echo "Creating database and table..."
psql -h localhost -p 5432 -U postgres -c "CREATE DATABASE test;"
psql -h localhost -p 5432 -U postgres -c "CREATE EXTENSION IF NOT EXISTS orioledb;"
psql -h localhost -p 5432 -U postgres -d test < create.sql 2>&1 | tee load_out.txt
if grep 'ERROR' load_out.txt
then
    exit 1
fi

# Expected: 'Access method: orioledb'
psql -h localhost -p 5432 -U postgres -d test -c "\d+ hits" | grep 'Access method:'

echo "Loading data..."
command time -f '%e' ./load.sh

echo "Running queries..."
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo docker exec -i $CONTAINER_NAME du -bcs /var/lib/postgresql/data/orioledb_data | grep total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
