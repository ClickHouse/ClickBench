#!/bin/bash

# Install

sudo apt-get update
sudo apt-get install -y mariadb-server
sudo bash -c "echo -e '[mysql]\nlocal-infile=1\n\n[mysqld]\nlocal-infile=1\n' > /etc/mysql/conf.d/local_infile.cnf"

# size innodb buffer based on available RAM
# use 75% of total
sudo bash -c "awk '/MemTotal/ { printf \"innodb_buffer_pool_size=%.0fG \n\", \$2*0.75/1024/1024 }' /proc/meminfo > /etc/mysql/buffer.conf"

sudo service mariadb restart

# Load the data

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

sudo mariadb -e "CREATE DATABASE test"
sudo mariadb test < create.sql

time split -l 10000 --filter="mariadb test -e \"SET sql_log_bin = 0; LOAD DATA LOCAL INFILE '/dev/stdin' INTO TABLE hits;\""

./run.sh 2>&1 | tee log.txt

sudo du -bcs /var/lib/mysql

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) days? )?(([0-9.]+) hours? )?(([0-9.]+) min )?([0-9.]+) sec\).*?$/\2,\4,\6,\7/' |
  awk -F, '{ if ($1 == "null") { print } else { print $1 * 86400 + $2 * 3600 + $3 * 60 + $4 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
