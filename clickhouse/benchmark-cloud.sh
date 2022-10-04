#!/bin/bash

# Go to https://clickhouse.cloud/ and create a service.
# To get results for various scale, go to "Actions / Advanced Scaling" and turn the slider of the minimum scale to the right.
# The number of threads is "SELECT value FROM system.settings WHERE name = 'max_threads'".

# Load the data

export HOST=...
export PASSWORD=...

clickhouse-client --host "$HOST" --password "$PASSWORD" --secure < create.sql

clickhouse-client --host "$HOST" --password "$PASSWORD" --secure --query "
  INSERT INTO hits SELECT * FROM url('https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz')
" --time --use_structure_from_insertion_table_in_table_functions 1

# 343.455

# Run the queries

./run.sh

clickhouse-client --host "$HOST" --password "$PASSWORD" --secure --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
