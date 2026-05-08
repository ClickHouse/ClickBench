#!/bin/bash -e

# Hyrise: research in-memory column-oriented DBMS from HPI.
# https://github.com/hyrise/hyrise
#
# Hyrise has no upstream binary distribution and the build requires a recent
# toolchain (gcc-15 / clang-20). We build it inside Docker on top of Ubuntu
# 25.04, then ship just the binary and its runtime libs in a slim image.

sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client gzip

# Build the Hyrise server image.
sudo docker build -t clickbench-hyrise .

# Download the dataset (RFC-4180 CSV produced by ClickHouse).
rm -rf data
mkdir data
../download-hits-csv data
# hits.csv.json next to hits.csv tells Hyrise's CSV parser the column types.
cp hits.csv.json data/hits.csv.json
chmod -R 777 data

# Start the server. Hyrise is in-memory only, so no persistent volume is
# needed; the dataset is mounted read-only.
sudo docker run -d --name hyrise --rm -p 5432:5432 \
    -v "$(pwd)/data:/data:ro" \
    --ulimit nofile=1048576:1048576 \
    clickbench-hyrise

# Wait for the server to accept connections.
for _ in $(seq 1 120); do
    if psql -h 127.0.0.1 -p 5432 -U postgres -c 'SELECT 1' > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Load the data. The COPY statement creates the `hits` table from the column
# definitions in hits.csv.json next to the data file.
echo -n "Load time: "
command time -f '%e' \
    psql -h 127.0.0.1 -p 5432 -U postgres -q \
        -c "COPY hits FROM '/data/hits.csv' WITH (FORMAT CSV);"

# Hyrise has no on-disk persistence; report the total in-memory segment size
# of the hits table from the meta_segments meta table.
echo -n "Data size: "
psql -h 127.0.0.1 -p 5432 -U postgres -t -A \
    -c "SELECT SUM(estimated_size_in_bytes) FROM meta_segments WHERE table_name = 'hits';"

# Run the benchmark.
./run.sh 2>&1 | tee log.txt

# Pretty-print results: 43 lines of [t1, t2, t3] (seconds).
cat log.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' |
    sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

# Cleanup.
sudo docker stop hyrise > /dev/null 2>&1 || true
rm -rf data
