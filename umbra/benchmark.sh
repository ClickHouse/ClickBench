#!/bin/bash

# Ubuntu
sudo apt-get update
sudo apt-get install -y docker.io postgresql-client gzip

# Amazon Linux
# yum install nc postgresql15

# Download + uncompress hits
rm -rf data
mkdir data
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz
mv hits.tsv data
chmod 777 -R data

# I spend too much time here battling cryptic error messages only to find out that the data needs to be in some separate directory
rm -rf db
mkdir db
chmod 777 -R db

# https://hub.docker.com/r/umbradb/umbra
docker run -d -v ./db:/var/db -v ./data:/data -p 5432:5432 --ulimit nofile=1048576:1048576 --ulimit memlock=8388608:8388608 umbradb/umbra:25.07
sleep 5 # Things below fail otherwise ...

start=$(date +%s%3N)
PGPASSWORD=postgres psql -p 5432 -h 127.0.0.1 -U postgres -f create.sql
end=$(date +%s%3N)
echo "Load Time: $(( (end - start) / 1000 ))"

./run.sh 2>&1 | tee log.txt

# Calculate persistence size
sudo chmod 777 -R db # otherwise 'du' complains about permission denied
echo -n "Data size: "
du -bcs db

# Pretty-printing
cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

# Cleanup
docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q) && docker volume prune --all --force
rm -rf data db
