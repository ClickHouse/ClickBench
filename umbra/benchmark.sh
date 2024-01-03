#!/bin/bash

sudo apt-get update
sudo apt-get install -y postgresql-client gzip

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
chmod 777 ~ hits.tsv

rm -rf umbra-24-01-03.tar.xz umbra
wget --no-verbose --continue 'https://db.in.tum.de/~schmidt/umbra-24-01-03.tar.xz'
tar -xf umbra-24-01-03.tar.xz

rm -rf db
mkdir db

export USEDIRECTIO=1
umbra/bin/sql -createdb db/umbra.db <<<"ALTER ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'password';"

umbra/bin/server -createSSLFiles -certFile db/umbra.cert -keyFile db/umbra.pem -address 0.0.0.0 db/umbra.db &> umbra.log &
sleep 1

psql -h /tmp -U postgres -t < create.sql
psql -h /tmp -U postgres -t -c '\timing' -c "copy hits from 'hits.tsv' with (format text);"

./run.sh 2>&1 | tee log.txt

du -bcs db/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

killall server
rm -rf hits.tsv
