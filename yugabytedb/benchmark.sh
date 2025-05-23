#!/bin/bash

MODE=$1

YDBVERSION=2.25.2.0
YDBBUILD=b359

sudo apt-get update
sudo apt-get upgrade -y

# Needed dependencies
sudo apt-get install python3 locales -y
sudo locale-gen en_US.UTF-8
# Should now include en_US.utf8
locale -a

if [[ $MODE == "setup" ]]; then
  # Set OS settings as recommended in https://docs.yugabyte.com/preview/deploy/manual-deployment/system-config
  echo "Writing ulimits to ~/.bashrc. Adapt the shell profile if needed."
  echo "ulimit -c unlimited
  ulimit -d unlimited
  ulimit -e 0
  ulimit -f unlimited
  ulimit -i 119934
  ulimit -l 64
  ulimit -m unlimited
  ulimit -n 1048576
  ulimit -q 819200
  ulimit -r 0
  ulimit -s 8192
  ulimit -t unlimited
  ulimit -u 12000
  ulimit -v unlimited
  ulimit -x unlimited" >> ~/.bashrc
  sudo bash -c 'sysctl vm.swappiness=0 >> /etc/sysctl.conf'
  sudo sysctl kernel.core_pattern=/home/yugabyte/cores/core_%p_%t_%E
  sudo sysctl -w vm.max_map_count=262144
  sudo bash -c 'sysctl vm.max_map_count=262144 >> /etc/sysctl.conf'

  echo "Setup done. Please log out and reboot the machine."
  exit 0
elif [[ $MODE == "run" ]]; then
  # Verify settings when setup was ran
  sysctl vm.max_map_count
  ulimit -a
  # Enable transparent huge pages until next reboot
  sudo bash -c "echo always > /sys/kernel/mm/transparent_hugepage/enabled"

  wget https://software.yugabyte.com/releases/$YDBVERSION/yugabyte-$YDBVERSION-$YDBBUILD-linux-x86_64.tar.gz
  tar xvfz yugabyte-$YDBVERSION-$YDBBUILD-linux-x86_64.tar.gz
  mv ./yugabyte-$YDBVERSION ./yugabyte
  # Should print "INSTALL PASSED"
  ./yugabyte/bin/post_install.sh

  ./yugabyte/bin/yugabyted start --advertise_address 127.0.0.1 --ui false --background true

  wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
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
else
  echo "Unknown mode '$MODE'. Expected one of: 'setup', 'run'."
fi;