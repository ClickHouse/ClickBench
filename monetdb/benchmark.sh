#!/bin/bash

# Install

echo "deb https://dev.monetdb.org/downloads/deb/ $(lsb_release -cs) monetdb" | sudo tee /etc/apt/sources.list.d/monetdb.list

sudo wget --output-document=/etc/apt/trusted.gpg.d/monetdb.gpg https://www.monetdb.org/downloads/MonetDB-GPG-KEY.gpg
sudo apt-get update -y
sudo apt-get install -y monetdb5-sql monetdb-client dos2unix net-tools

sudo monetdbd create /var/lib/monetdb
sudo usermod -a -G monetdb $USER

for _ in {1..300}
do
  sudo monetdb create test && break
  sleep 1
done
sudo monetdb release test

sudo apt-get install -y expect

./query.expect "$(cat create.sql)"

../lib/download-tsv.sh
chmod 777 ~ hits.tsv

echo -n "Load time: "
command time -f '%e' ./query.expect "COPY INTO hits FROM '$(pwd)/hits.tsv' USING DELIMITERS '\t'"

# 99997497 affected rows
# clk: 15:39 min

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo du -bcs /var/monetdb5/ | grep total

cat log.txt | dos2unix -f | grep -P 'clk|tuple' |
    awk '/tuple/ { ok = 1 } /clk/ { if (ok) { if ($3 == "ms") { print $2 / 1000 } else { print $2 } } else { print "null" }; ok = 0 }' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
