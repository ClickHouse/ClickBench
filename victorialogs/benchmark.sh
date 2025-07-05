#!/bin/bash

# Install

RELEASE_VERSION=v1.10.1-victorialogs

# Stop the existing victorialogs instance if any and drop its data
while true
do
    pidof victoria-logs-prod && kill `pidof victoria-logs-prod` || break
    sleep 1
done
rm -rf victoria-logs-data

# Download and start victorialogs
wget --continue --progress=dot:giga https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${RELEASE_VERSION}/victoria-logs-linux-amd64-${RELEASE_VERSION}.tar.gz
tar xzf victoria-logs-linux-amd64-${RELEASE_VERSION}.tar.gz
./victoria-logs-prod -loggerOutput=stdout -retentionPeriod=20y -search.maxQueryDuration=5m > server.log &

while true
do
    curl -s http://localhost:9428/select/logsql/query -d 'query=_time:2100-01-01Z' && break
    sleep 1
done

# Load the data

wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.json.gz
gunzip hits.json.gz
echo -n "Load time: "
command time -f '%e' cat hits.json | split -n r/8 -d --filter="curl -sS -T - -X POST 'http://localhost:9428/insert/jsonline?_time_field=EventTime&_stream_fields=AdvEngineID,CounterID'"

# Run the queries

./run.sh

# Determine on-disk size of the ingested data

echo -n "Data size: "
du -sb victoria-logs-data
