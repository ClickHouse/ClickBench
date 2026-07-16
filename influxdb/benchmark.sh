#!/bin/bash

set -eu

export DEBIAN_FRONTEND=noninteractive

# Install dependencies and the InfluxDB 3 Core binary directly. We bypass the
# upstream install_influxdb3.sh installer because it is interactive and not
# suited for unattended runs.
sudo apt-get update -qq >/dev/null
sudo apt-get install -y -qq python3 python3-requests curl jq time >/dev/null

INFLUX_VERSION=3.9.2
case "$(uname -m)" in
    x86_64|amd64)  INFLUX_ARTIFACT=linux_amd64 ;;
    aarch64|arm64) INFLUX_ARTIFACT=linux_arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

INFLUX_TGZ="influxdb3-core-${INFLUX_VERSION}_${INFLUX_ARTIFACT}.tar.gz"
wget --continue -q "https://dl.influxdata.com/influxdb/releases/${INFLUX_TGZ}"
rm -rf "influxdb3-core-${INFLUX_VERSION}"
tar -xzf "${INFLUX_TGZ}"
INFLUXDB3="${PWD}/influxdb3-core-${INFLUX_VERSION}/influxdb3"

# Start the server with local-file storage and authentication disabled.
# The --wal-* tunings reduce per-second fsync churn during the multi-hour
# load and let more write requests accumulate in memory before being
# rejected with back-pressure.
mkdir -p ./influxdb3-data
start_server() {
    nohup "${INFLUXDB3}" serve \
        --node-id node0 \
        --object-store file \
        --data-dir "${PWD}/influxdb3-data" \
        --http-bind 127.0.0.1:8181 \
        --without-auth \
        --wal-max-write-buffer-size 1000000 \
        --max-http-request-size 67108864 \
        --exec-mem-pool-bytes 80% \
        > influxdb3.log 2>&1 &
    INFLUXDB_PID=$!
    echo "InfluxDB PID: ${INFLUXDB_PID}"

    for _ in $(seq 1 300); do
        curl -sf http://localhost:8181/health > /dev/null && return
        sleep 1
    done
    echo "Timed out waiting for InfluxDB to start" >&2
    return 1
}

restart_server() {
    # SIGTERM forces the WAL to drain into Parquet and the in-memory write
    # buffers to flush; the next start comes up with no WAL to replay.
    kill -TERM "${INFLUXDB_PID}" 2>/dev/null || true
    wait "${INFLUXDB_PID}" 2>/dev/null || true
    start_server
}

start_server

"${INFLUXDB3}" create database hits

# Download the dataset and load it via line protocol.
../download-hits-tsv

# Load in chunks, restarting the server between each chunk so the WAL drains
# into Parquet. With one monolithic load, every Parquet file ends up covering
# the same broad time range (16 parallel writers interleave timestamps across
# the whole dataset), and InfluxDB 3.9.2's regroup_files optimizer hits an
# internal "overlapping ranges within same file" assertion at query time.
# Chunking keeps each Parquet file's [min_time, max_time] bounded to a
# disjoint slice, so subsequent queries can plan successfully.
TOTAL_ROWS=99997497
CHUNKS=10
CHUNK_ROWS=$(( (TOTAL_ROWS + CHUNKS - 1) / CHUNKS ))

load_t0=$(date +%s)
for i in $(seq 0 $((CHUNKS - 1))); do
    chunk_start=$((i * CHUNK_ROWS))
    chunk_end=$(( (i + 1) * CHUNK_ROWS ))
    if [ "$chunk_end" -gt "$TOTAL_ROWS" ]; then chunk_end=$TOTAL_ROWS; fi
    echo "Chunk $((i + 1))/${CHUNKS}: rows ${chunk_start}..${chunk_end}"
    python3 load.py --start-row "$chunk_start" --end-row "$chunk_end"
    # Drain WAL so this chunk lands in its own Parquet files before the
    # next chunk starts mixing more timestamps into the in-memory buffer.
    restart_server
done
echo "Load time: $(($(date +%s) - load_t0))"

# Server is already freshly restarted from the last chunk's drain, so no
# additional restart is needed before the query phase.

# Run queries.
./run.sh | tee log.txt

echo -n "Data size: "
du -bcs ./influxdb3-data | grep total | awk '{print $1}'

kill "${INFLUXDB_PID}" || true
