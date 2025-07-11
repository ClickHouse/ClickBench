#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y sqlite3

sqlite3 mydb < create.sql

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz

echo -n "Load time: "
command time -f '%e' sqlite3 mydb '.import --csv hits.csv hits'
echo -n "Data size: "
wc -c mydb

./run.sh 2>&1 | tee log.txt

cat log.txt |
  grep -P '^real|^Error|Parse error' |
  sed -r -e 's/^(Error|Parse error).*$/null/; s/^real\s*([0-9.]+)m([0-9.]+)s$/\1 \2/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if ($1 == "null") { skip = 1 } else { if (i % 3 == 0) { printf "[" }; printf skip ? "null" : $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; skip = 0; } }'
