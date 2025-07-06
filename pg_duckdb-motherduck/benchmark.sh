#!/bin/bash

set -e

# Note: To get equivalent performance you should be running from
# AWS US-EAST-1 region or as close to there as possible. Otherwise
# you'll see additional latency.

# Sign up for MotherDuck.
# Go to the web ui and obtain a token
# https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/
# Save the token as the MOTHERDUCK_TOKEN environment variable:
# export MOTHERDUCK_TOKEN=...
# create a database called pgclick in the motherduck UI or duckdb cli
# `CREATE DATABASE pgclick`

if [ -z "${MOTHERDUCK_TOKEN}" ]; then
    echo "Error: MOTHERDUCK_TOKEN is not set."
    exit 1
fi

sudo apt-get update -y
sudo apt-get install -y docker.io postgresql-client
sudo docker run -d --name pgduck --network=host -e POSTGRES_PASSWORD=duckdb -e MOTHERDUCK_TOKEN=${MOTHERDUCK_TOKEN} pgduckdb/pgduckdb:17-v0.3.1 -c duckdb.motherduck_enabled=true

# Give postgres time to start running
sleep 10

echo -n "Load time: "
command time -f '%e' ./load.sh

./run.sh 2>&1 | tee log.txt

# Go to https://app.motherduck.com and execute:
# `SELECT database_size FROM pragma_database_size() WHERE database_name = 'pgclick'`
# 25 GB

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
