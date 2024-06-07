#!/bin/bash

# Install

wget https://github.com/questdb/questdb/releases/download/8.0.0/questdb-8.0.0-rt-linux-amd64.tar.gz
tar xf questdb*.tar.gz --one-top-level=questdb --strip-components 1
questdb/bin/questdb.sh start

while ! nc -z localhost 9000; do
  sleep 0.1
done

sed -i 's/query.timeout.sec=60/query.timeout.sec=500/' ~/.questdb/conf/server.conf
questdb/bin/questdb.sh stop
questdb/bin/questdb.sh start

# Import the data

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz

curl -G --data-urlencode "query=$(cat create.sql)" 'http://localhost:9000/exec?timings=true'
time curl -F data=@hits.csv 'http://localhost:9000/imp?name=hits'

# Run queries

./run.sh 2>&1 | tee log.txt

du -bcs ~/.questdb/db/hits*

cat log.txt | grep -P '"timings"|"error"|null' | sed -r -e 's/^.*"error".*$/null/; s/^.*"execute":([0-9]*),.*$/\1/' |
  awk '{ print ($1) / 1000000000 }' | sed -r -e 's/^0$/null/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
