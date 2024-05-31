    wget --no-verbose --continue -O /tmp/hits.parquet https://datasets.clickhouse.com/hits_compatible/hits.parquet
  fi
  if ! sudo docker exec paradedb sh -c '[ -f /tmp/hits.parquet ]'; then
    sudo docker cp /tmp/hits.parquet paradedb:/tmp/hits.parquet
  fi
elif [ $FLAG_WORKLOAD == "partitioned" ]; then
  if [ ! -e /tmp/partitioned/ ]; then
    mkdir -p /tmp/partitioned
    seq 0 99 | xargs -P100 -I{} bash -c 'wget --no-verbose --directory-prefix /tmp/partitioned --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'
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
                                                                                                                