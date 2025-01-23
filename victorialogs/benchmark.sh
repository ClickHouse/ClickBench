#!/bin/bash

# Install

RELEASE_VERSION=v1.7.0-victorialogs

wget --no-verbose --continue https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${RELEASE_VERSION}/victoria-logs-linux-amd64-${RELEASE_VERSION}.tar.gz
tar xzf victoria-logs-linux-amd64-${RELEASE_VERSION}.tar.gz
./victoria-logs-prod -loggerOutput=stdout -retentionPeriod=20y -search.maxQueryDuration=5m > server.log &

while true
do
    curl http://localhost:9428/select/logsql/query -d 'query=_time:2100-01-01Z' && break
    sleep 1
done

# Load the data

wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/hits.json.gz
gunzip hits.json.gz
time cat hits.json | split -n r/8 -d --filter="curl -T - -X POST 'http://localhost:9428/insert/jsonline?_time_field=EventTime&_stream_fields=AdvEngineID,CounterID'"

# Run the queries

./run.sh

# Determine on-disk size of the ingested data

du -sb victoria-logs-data
