#!/bin/bash -e

# Go to https://clickhouse.cloud/ and create a service.
# To get results for various scale, go to "Actions / Advanced Scaling" and turn the slider of the minimum scale to the right.
# The number of threads is "SELECT value FROM system.settings WHERE name = 'max_threads'".

# Load the data

# export FQDN=...
# export PASSWORD=...

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure < create.sql

MAX_INSERT_THREADS=$(clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT intDiv(getSetting('max_threads'), 4)")

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --time --enable-parallel-replicas 1 --max-insert-threads $MAX_INSERT_THREADS --query "
  INSERT INTO hits SELECT * FROM url('https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet')
"

# 343.455

# Run the queries

./run.sh

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
