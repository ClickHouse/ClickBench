#!/bin/bash

PARADEDB_VERSION=0.8.4
FLAG_WORKLOAD=single

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Options:"
  echo " -h (optional),   Display this help message"
  echo " -w (optional),   Workload type, either <single> or <partitioned>. Default is <single>."
  exit 1
}

cleanup() {
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
      case "$FLAG_WORKLOAD" in single | partitioned):
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

echo ""
echo "Installing dependencies..."
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
echo "ParadeDB is ready!"

echo ""
echo "Downloading ClickBench dataset ($FLAG_WORKLOAD)..."
if [ $FLAG_WORKLOAD == "single" ]; then
  if [ ! -e /tmp/hits.parquet ]; then
    wget --continue --progress=dot:giga -O /tmp/hits.parquet https://datasets.clickhouse.com/hits_compatible/hits.parquet
  fi
  if ! sudo docker exec paradedb sh -c '[ -f /tmp/hits.parquet ]'; then
    sudo docker cp /tmp/hits.parquet paradedb:/tmp/hits.parquet
  fi
elif [ $FLAG_WORKLOAD == "partitioned" ]; then
  if [ ! -e /tmp/partitioned/ ]; then
    mkdir -p /tmp/partitioned
    seq 0 99 | xargs -P100 -I{} bash -c 'wget --directory-prefix /tmp/partitioned --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
  fi
  if ! sudo docker exec paradedb sh -c '[ -f /tmp/partitioned ]'; then
    sudo docker cp /tmp/partitioned paradedb:tmp
  fi
else
  echo "Invalid workload type: $FLAG_WORKLOAD"
  exit 1
fi

echo ""
echo "Creating database..."
export PGPASSWORD='postgres'
if [ $FLAG_WORKLOAD == "single" ]; then
  psql -h localhost -U postgres -d mydb -p 5432 -t < create-single.sql
else
  psql -h localhost -U postgres -d mydb -p 5432 -t < create-partitioned.sql
fi

# load_time is zero, since the data is directly read from the Parquet file(s)
# Time: 0000000.000 ms (00:00.000)

echo ""
echo "Running queries..."
./run.sh 2>&1 | tee log.txt

# data_size is the Parquet file(s) total size
# 14779976446

echo ""
echo "Parsing results..."
cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
