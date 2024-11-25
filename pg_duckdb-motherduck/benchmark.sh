#!/bin/bash

set -ex

#sudo apt-get update
#sudo apt-get install -y docker.io
#sudo apt-get install -y postgresql-client

# Ubuntu:
# snap install docker
# sudo apt install posgresql-client-common
# sudo apt install postgresql-client-16

# Note: To get equivalent performance you should be runnign from
# AWS US-EAST-1 region or as close to there as possible. Otherwise
# you'll see additional latency.

# Sign up for MotherDuck. 
# Go to the web ui and obtain a token
# https://motherduck.com/docs/key-tasks/authenticating-and-connecting-to-motherduck/authenticating-to-motherduck/
# Save the token as the motherduck_token environment variable:
# export motherduck_token=...
# create a database called pgclick in the motherduck UI or duckdb cli
# `CREATE DATABASE pgclick`
# You will also need to create dummy table in that database. For example, run
# `create table pgclick.foo as SELECT 1 as a;`
# (https://github.com/duckdb/pg_duckdb/issues/450)


sudo docker run -d --name pgduck -e POSTGRES_PASSWORD=duckdb -e MOTHERDUCK_TOKEN=$MOTHERDUCK_TOKEN pgduckdb/pgduckdb:16-main -c duckdb.motherduck_enabled=true

# Give postgres time to start running
sleep 5

./load.sh 2>&1 | tee load_log.txt

./run.sh 2>&1 | tee log.txt

# Go to motherduck UI and execute:
# `SELECT database_size FROM pragma_database_size() WHERE database_name = 'pgclick'`
# 25 GB

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

