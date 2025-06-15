#!/bin/bash

# Ubuntu
sudo apt-get update
sudo apt-get install -y postgresql-client gzip

# Amazon Linux
# yum install nc postgresql15

# Download + uncompress hits
rm -rf hits.tsv
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz
chmod 777 hits.tsv

# I spend too much time here battling cryptic error messages only to find out that the data needs to be in some separate directory
rm -rf /data/db
mkdir /data/db
cp hits.tsv /data/db/
chmod 777 -R /data/db

# https://hub.docker.com/r/umbradb/umbra
docker run -d -v /data/db:/var/db -p 5432:5432 --ulimit nofile=1048576:1048576 --ulimit memlock=8388608:8388608 umbradb/umbra:latest
sleep 5 # Things below fail otherwise ...

PGPASSWORD=postgres psql -p 5432 -h 127.0.0.1 -U postgres -f create.sql

./run.sh 2>&1 | tee log.txt

# Calculate persistence size
sudo chmod 777 -R /data/db # otherwise 'du' complains about permission denied
rm /data/db/hits.tsv # not part of the database persistency
du -bcs /data/db/

# Pretty-printing
cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

# Cleanup
docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q) && docker volume prune --all --force
rm -rf /data/db
