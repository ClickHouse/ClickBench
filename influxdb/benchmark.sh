#!/bin/bash

set -eu

# Install dependencies and the InfluxDB 3 Core binary directly. We bypass the
# upstream install_influxdb3.sh installer because it is interactive and not
# suited for unattended runs.

sudo apt-get update -y
sudo apt-get install -y python3 python3-pip curl jq time
pip3 install --break-system-packages requests

INFLUX_VERSION=3.9.2
case "$(uname -m)" in
    x86_64|amd64)  INFLUX_ARTIFACT=linux_amd64 ;;
    aarch64|arm64) INFLUX_ARTIFACT=linux_arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

INFLUX_TGZ="influxdb3-core-${INFLUX_VERSION}_${INFLUX_ARTIFACT}.tar.gz"
wget --continue --progress=dot:giga \
    "https://dl.influxdata.com/influxdb/releases/${INFLUX_TGZ}"
rm -rf "influxdb3-core-${INFLUX_VERSION}"
tar -xzf "${INFLUX_TGZ}"
INFLUXDB3="${PWD}/influxdb3-core-${INFLUX_VERSION}/influxdb3"

# Start the server with local-file storage and authentication disabled.
mkdir -p ./influxdb3-data
nohup "${INFLUXDB3}" serve \
    --node-id node0 \
    --object-store file \
    --data-dir "${PWD}/influxdb3-data" \
    --http-bind 127.0.0.1:8181 \
    --without-auth \
    > influxdb3.log 2>&1 &
INFLUXDB_PID=$!
echo "InfluxDB PID: ${INFLUXDB_PID}"

for _ in $(seq 1 300); do
    curl -sf http://localhost:8181/health > /dev/null && break
    sleep 1
done

"${INFLUXDB3}" create database hits

# Download the dataset and load it via line protocol.
../download-hits-tsv

echo -n "Load time: "
command time -f '%e' python3 load.py

# Run queries.
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
du -bcs ./influxdb3-data | grep total | awk '{print $1}'

kill "${INFLUXDB_PID}" || true
