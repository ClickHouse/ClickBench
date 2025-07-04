#!/bin/bash

YDBVERSION=2.25.2.0
YDBBUILD=b359

sudo apt-get update
sudo apt-get upgrade -y

# Needed dependencies
sudo apt-get install python3 locales -y
sudo locale-gen en_US.UTF-8
# Should now include en_US.utf8
locale -a

wget --continue --progress=dot:giga https://software.yugabyte.com/releases/$YDBVERSION/yugabyte-$YDBVERSION-$YDBBUILD-linux-x86_64.tar.gz
tar xvfz yugabyte-$YDBVERSION-$YDBBUILD-linux-x86_64.tar.gz
mv ./yugabyte-$YDBVERSION ./yugabyte
# Should print "INSTALL PASSED"
./yugabyte/bin/post_install.sh

./yugabyte/bin/yugabyted start --advertise_address 127.0.0.1 --ui false --background true

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d -f hits.tsv.gz

./yugabyte/bin/ysqlsh -U yugabyte -c "CREATE DATABASE test;"
./yugabyte/bin/ysqlsh -U yugabyte -c "ALTER DATABASE test SET temp_file_limit=-1;"
./yugabyte/bin/ysqlsh -U yugabyte -d test -c "DROP DATABASE IF EXISTS yugabyte;"
./yugabyte/bin/ysqlsh -U yugabyte -d test -t < create.sql

# takes around ~78 minutes on AWS EC2 c6a.4xlarge (500GB gp2)
time ./load.sh

./run.sh 2>&1 | tee log.txt

# 76977854454 bytes
./yugabyte/bin/ysqlsh -U yugabyte -d test -c "SELECT pg_total_relation_size('public.hits') AS TOTAL_TABLE_SIZE_IN_BYTES;"

grep -oP 'Time: \d+\.\d+ ms' log.txt |
  sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
