#!/bin/bash

# The benchmark should be run in the eu-central-1 (Frankfurt) region.
# Allocate a network-optimized ("n") machine, e.g. c5n.4xlarge.

# Install

curl https://clickhouse.com/ | sh
sudo DEBIAN_FRONTEND=noninteractive ./clickhouse install

# Load the data

clickhouse-client --time < create.sql

# Run the queries

./run.sh

clickhouse-client --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
