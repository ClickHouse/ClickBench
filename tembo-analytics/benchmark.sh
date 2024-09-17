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
echo "Creating database..."
export PGPASSWORD='postgres'
if [ $FLAG_WORKLOAD == "single" ]; then
  psql -X 'postgresql://postgres:S9PPuI4kly8Rs0yu@peevishly-conclusive-nighthawk.data-1.use1.tembo-development.com:5432/postgres' -t < create-single.sql
else
  psql -X 'postgresql://postgres:S9PPuI4kly8Rs0yu@peevishly-conclusive-nighthawk.data-1.use1.tembo-development.com:5432/postgres' -t < create-partitioned.sql
fi

echo ""
echo "Running queries..."
./run.sh 2>&1 | tee log.txt

# data_size is the Parquet file(s) total size
# 14779976446

echo ""
echo "Parsing results..."
cat log.txt | grep -Eo 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
