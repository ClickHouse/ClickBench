#!/bin/bash -e

# Go to https://clickhouse.cloud/ and create a service.
# To get results for various scale, go to "Actions / Advanced Scaling" and turn the slider of the minimum scale to the right.
# The number of threads is "SELECT value FROM system.settings WHERE name = 'max_threads'".

# Load the data

# export FQDN=...
# export PASSWORD=...

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure < create.sql

echo -n "Load time: "
command time -f '%e' clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "
  INSERT INTO hits SELECT * FROM url('https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/hits.tsv.gz')
"

# 343.455

# Run the queries

./run.sh

echo -n "Data size: "
clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
