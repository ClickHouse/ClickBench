#!/bin/bash -e

# Hyrise is a research in-memory column-oriented database from HPI.
# https://github.com/hyrise/hyrise
#
# Hyrise has no pre-built binary distribution; it must be compiled from source.
# Hyrise's install_dependencies.sh requires Ubuntu 25.04 or newer (for gcc-15
# and clang-20). On older Ubuntu releases the build will fail.

# Install Hyrise dependencies (this may pull in many packages and a fresh
# compiler toolchain).
sudo apt-get update -y
sudo apt-get install -y git cmake ninja-build postgresql-client

git clone --recursive https://github.com/hyrise/hyrise.git hyrise-src
cd hyrise-src
HYRISE_HEADLESS_SETUP=1 ./install_dependencies.sh

# Build only the server binary in Release mode.
mkdir -p cmake-build-release
cd cmake-build-release
cmake -GNinja -DCMAKE_BUILD_TYPE=Release ..
ninja hyriseServer
cd ../..

# Download the dataset (CSV format, RFC-4180 compliant).
../download-hits-csv

# Start the server in the background. Hyrise listens on the PostgreSQL wire
# protocol; no authentication is required.
./hyrise-src/cmake-build-release/hyriseServer 5432 > server.log 2>&1 &
SERVER_PID=$!

# Wait for the server to accept connections.
for _ in $(seq 1 60); do
    if psql -h 127.0.0.1 -p 5432 -U postgres -c 'SELECT 1' > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Create the table.
psql -h 127.0.0.1 -p 5432 -U postgres -f create.sql

# Load the data and measure load time. The COPY statement uses Hyrise's CSV
# parser, which expects RFC-4180 formatted input (the format produced by
# download-hits-csv).
echo -n "Load time: "
command time -f '%e' psql -h 127.0.0.1 -p 5432 -U postgres -c "COPY hits FROM '$(pwd)/hits.csv' WITH (FORMAT CSV);"

# Hyrise is in-memory only, so report the estimated total segment size of the
# hits table as the data size.
echo -n "Data size: "
psql -h 127.0.0.1 -p 5432 -U postgres -t -A -c \
    "SELECT SUM(estimated_size_in_bytes) FROM meta_segments WHERE table_name = 'hits';"

# Run the benchmark.
./run.sh 2>&1 | tee log.txt

# Pretty-print results: 43 lines of [t1, t2, t3] (seconds).
cat log.txt | grep -oP 'Time: \d+\.\d+ ms|psql: error' |
    sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/; s/^.*psql: error.*$/null/' |
    awk '{ if (i % 3 == 0) { printf "[" }; if ($1 == "null") { printf $1 } else { printf $1 / 1000 }; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

# Cleanup.
kill ${SERVER_PID} || true
wait ${SERVER_PID} 2>/dev/null || true
