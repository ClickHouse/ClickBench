#!/bin/bash

# Install

sudo apt-get update -y
sudo apt-get install -y docker.io

mkdir infobright
sudo docker run --name mysql_ib -e MYSQL_ROOT_PASSWORD=mypass -v $(pwd)/infobright:/mnt/mysql_data -p 5029:5029 -p 5555 -d flolas/infobright

sudo docker run -i --rm --network host mysql:5 mysql --host 127.0.0.1 --port 5029 --user=root --password=mypass -e "CREATE DATABASE test"
sudo docker run -i --rm --network host mysql:5 mysql --host 127.0.0.1 --port 5029 --user=root --password=mypass --database=test -e "$(cat create.sql)"

# Load the data

../lib/download-tsv.sh

# ERROR 2 (HY000) at line 1: Wrong data or column definition. Row: 93557187, field: 100.
head -n 90000000 hits.tsv > hits90m.tsv

echo -n "Load time: "
command time -f '%e' sudo docker run -i --rm --volume $(pwd):/workdir --network host mysql:5 mysql --host 127.0.0.1 --port 5029 --user=root --password=mypass --database=test -e "SET sql_log_bin = 0;
    LOAD DATA LOCAL INFILE '/workdir/hits90m.tsv' INTO TABLE test.hits
    FIELDS TERMINATED BY '\\t' ENCLOSED BY '' ESCAPED BY '\\\\' LINES TERMINATED BY '\\n' STARTING BY ''"

# 38m37.466s

echo -n "Data size: "
sudo docker exec mysql_ib du -bcs /mnt/mysql_data/ /usr/local/infobright-4.0.7-x86_64/cache | grep total

# 13 760 341 294

./run.sh 2>&1 | tee log.txt

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) days? )?(([0-9.]+) hours? )?(([0-9.]+) min )?([0-9.]+) sec\).*?$/\2,\4,\6,\7/' |
  awk -F, '{ if ($1 == "null") { print } else { print $1 * 86400 + $2 * 3600 + $3 * 60 + $4 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
