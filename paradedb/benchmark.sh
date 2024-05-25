#!/bin/bash

# Run the ClickBench benchmarks for Docker version of ParadeDB.

PARADEDB_VERSION=0.7.2
FLAG_WORKLOAD=single

# TODO: Also make it work with S3
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo " -h (optional),   Display this help message"
  echo " -w (optional),   Workload type, either <single> or <partitioned>. Default is <single>."
  exit 1
}

cleanup() {
    echo ""
    echo "Cleaning up..."
    if sudo docker ps -q --filter "name=paradedb" | grep -q .; then
      sudo docker kill paradedb
    fi
    sudo docker rm paradedb
    echo "Done, goodbye!"
}

trap cleanup EXIT

while getopts "hw:" flag
do
  case $flag in
    h)
      usage
      ;;
    w)
      FLAG_WORKLOAD=$OPTARG
    case "$FLAG_WORKLOAD" in single | partitioned ): # Do nothing
        ;;
      *)
        usage
        ;;
    esac
    ;;
    *)
      usage
      ;;
  esac
done

sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client

echo ""
echo "Pulling ParadeDB image..."
sudo docker run \
  --name paradedb \
  -e POSTGRESQL_USERNAME=myuser \
  -e POSTGRESQL_PASSWORD=mypassword \
  -e POSTGRESQL_DATABASE=mydb \
  -e POSTGRESQL_POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  -d \
  paradedb/paradedb:$PARADEDB_VERSION

echo ""
echo "Waiting for ParadeDB to start..."
sleep 10

echo ""
echo "Downloading ClickBench dataset ($FLAG_WORKLOAD)..."
if [ $FLAG_WORKLOAD == "single" ]; then
    sudo docker exec -it paradedb bash -c "cd /tmp/ && curl -O -L -C - 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'"
elif [ $FLAG_WORKLOAD == "partitioned" ]; then
    # TODO: Test that this works
    sudo docker exec -it paradedb bash -c "cd /tmp/ && for i in $(seq 0 99); do curl -s -o hits_${i}.parquet -C - https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_${i}.parquet & done; wait"
else
    echo "Invalid workload type: $FLAG_WORKLOAD"
    exit 1
fi

echo ""
echo "Creating database..."
export PGPASSWORD='postgres'
psql -h localhost -U postgres -d mydb -p 5432 -t < create.sql

echo ""
echo "Running queries..."
./run.sh 2>&1 | tee log.txt

sudo docker exec -it paradedb du -bcs /bitnami/postgresql/data

# TODO: Edit this to the right amount
# 15415061091     /bitnami/postgresql/data
# 15415061091     total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
