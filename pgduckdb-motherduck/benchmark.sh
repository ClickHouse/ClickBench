#!/bin/bash

set -ex

#sudo apt-get update
#sudo apt-get install -y docker.io
#sudo apt-get install -y postgresql-client

# Ubuntu:
# snap install docker
# sudo apt install posgresql-client-common
# sudo apt install postgresql-client-16

USE_MOTHERDUCK=1

CONNECTION=postgres://postgres:duckdb@172.17.0.2:5432/postgres
# CONNECTION=postgres://postgres:duckdb@172.17.0.2:5432/postgres

if [[ $USE_MOTHERDUCK == 1 ]]; then
# Sign up for MotherDuck. Get a motherduck token.
# export MOTHERDUCK_TOKEN=... {from the MotherDuck UI}
# create a database called pgclick in the motherduck UI or duckdb cli
# you will also need to create dummy table in that database.For example, run
# create table pgclick.foo as SELECT 1 as a;
# (https://github.com/duckdb/pg_duckdb/issues/450)

sudo docker run -d --name pgduck -e POSTGRES_PASSWORD=duckdb -e MOTHERDUCK_TOKEN=$MOTHERDUCK_TOKEN pgduckdb/pgduckdb:16-main -c duckdb.motherduck_enabled=true

else

wget --no-verbose --continue https://datasets.clickhouse.com/hits_compatible/athena/hits.parquet
sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb -v ./hits.parquet:/tmp/hits.parquet pgduckdb/pgduckdb:16-main

fi

# Give postgres time to start running
sleep 5

./load.sh 2>&1 | tee load_log.txt
./run.sh 2>&1 | tee log.txt

if [[ $USE_MOTHERDUCK == 1 ]]; then
# Go to motherduck UI and execute:
# SELECT database_size FROM pragma_database_size()
# WHERE database_name = 'pgclick'
echo 'Fetch database size from the MotherDuck UI with `SELECT database_size FROM pragma_database_size()
 WHERE database_name = 'pgclick'`'

else
sudo docker exec -it pgduck du -bcs /var/lib/postgresql/data /tmp/hits.parquet
fi

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

