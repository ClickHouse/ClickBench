#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y python3-pip
pip install duckdb psutil

# Load the data

# Open https://app.motherduck.com/ and paste the contents of create.sql

# Then run:
# COPY hits FROM 'https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/hits.csv.gz'

# 4122 seconds

# Install the command line tool

wget https://github.com/duckdb/duckdb/releases/download/v0.9.2/duckdb_cli-linux-amd64.zip
unzip duckdb_cli-linux-amd64.zip

./duckdb

# .open md:
# Authenticate and obtain a token.
# export motherduck_token=...

# Run the queries

./run.sh 2>&1 | tee log.txt

cat log.txt | grep -P '^\d|Killed|Segmentation' | sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
