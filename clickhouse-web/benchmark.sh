#!/bin/bash

# The benchmark should be run in the eu-central-1 (Frankfurt) region.
# Allocate a network-optimized ("n") machine, e.g. c5n.4xlarge.

# Install

curl https://clickhouse.com/ | sh
sudo ./clickhouse install --noninteractive
sudo clickhouse start

# A directory for cache
sudo mkdir /dev/shm/clickhouse
sudo chown clickhouse:clickhouse /dev/shm/clickhouse

# Load the data

clickhouse-client --time < create.sql

# Run the queries

./run.sh

clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
