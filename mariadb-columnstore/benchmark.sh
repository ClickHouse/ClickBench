#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y docker.io
sudo docker run -d -p 3306:3306 -e ANALYTICS_ONLY=1 --name mcs_container mariadb/columnstore

export PASSWORD="tsFgm457%3cj"
sudo docker exec mcs_container mariadb -e "GRANT ALL PRIVILEGES ON *.* TO '$(whoami)'@'%' IDENTIFIED BY '${PASSWORD}';"

sudo apt-get install -y mariadb-client

mysql --password="${PASSWORD}" --host 127.0.0.1 -e "CREATE DATABASE test"
mysql --password="${PASSWORD}" --host 127.0.0.1 test < create.sql

# Load the data

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

echo -n "Load time: "
command time -f '%e' mysql --password="${PASSWORD}" --host 127.0.0.1 test -e "SET sql_log_bin = 0;
    LOAD DATA LOCAL INFILE 'hits.tsv' INTO TABLE hits
    FIELDS TERMINATED BY '\\t' ENCLOSED BY '' ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' STARTING BY ''"

# 41m47.856s

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
sudo docker exec mcs_container du -bcs /var/lib/columnstore | grep total

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
