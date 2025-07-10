#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y docker.io
sudo apt-get install -y postgresql-client

export PGPASSWORD=mypass
sudo docker run -d --name citus -p 5432:5432 -e POSTGRES_PASSWORD=$PGPASSWORD citusdata/citus:11.0

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

echo "*:*:*:*:mypass" > .pgpass
chmod 400 .pgpass

psql -U postgres -h localhost -d postgres -t -c 'CREATE DATABASE test'
psql -U postgres -h localhost -d postgres test -t < create.sql
echo -n "Load time: "
command time -f '%e' psql -U postgres -h localhost -d postgres test -q -t -c "\\copy hits FROM 'hits.tsv'"

# COPY 99997497
# Time: 1579203.482 ms (26:19.203)

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo docker exec -i citus du -bcs /var/lib/postgresql/data | grep total

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
