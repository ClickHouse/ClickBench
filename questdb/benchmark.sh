#!/bin/bash

# Install

wget https://github.com/questdb/questdb/releases/download/7.3.3/questdb-7.3.3-rt-linux-amd64.tar.gz
tar xf questdb*.tar.gz
questdb-7.3.3-rt-linux-amd64/bin/questdb.sh start

while ! nc -z localhost 9000; do
  sleep 0.1
done

sed -i 's/query.timeout.sec=60/query.timeout.sec=500/' ~/.questdb/conf/server.conf
questdb-7.3.3-rt-linux-amd64/bin/questdb.sh stop
questdb-7.3.3-rt-linux-amd64/bin/questdb.sh start

# Import the data

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz

curl -G --data-urlencode "query=$(cat create.sql)" 'http://localhost:9000/exec?timings=true'
time curl -F data=@hits.csv 'http://localhost:9000/imp?name=hits'

./run.sh 2>&1 | tee log.txt

du -bcs ~/.questdb/db/hits*

cat log.txt | grep -P '"timings"|"error"|null' | sed -r -e 's/^.*"error".*$/null/; s/^.*"compiler":([0-9]*),"execute":([0-9]*),.*$/\1 \2/' |
  awk '{ print ($1 + $2) / 1000000000 }' | sed -r -e 's/^0$/null/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
