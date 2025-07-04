#!/bin/bash

shopt -s expand_aliases

MODE=${1:=tiflash}

TIDBVERSION=8.5.1

TIUP_HOME=$(pwd)
export TIUP_HOME
DB_NAME=test
TABLE_NAME=hits
DATA_DIR=/tmp/data

if [[ ! $MODE =~ ^(tikv|tikv-tiflash|tiflash)$ ]]; then
   echo "Unknown mode: '$MODE'. Expected one of 'tikv', 'tikv-tiflash', 'tiflash'"
   exit 1
fi

sudo apt-get update
sudo apt-get upgrade -y
# TiUp installer depends on curl
sudo DEBIAN_FRONTEND=noninteractive apt-get install curl mysql-client -y
# Needs to be installed and setup for TiFlash; 2-107 corresponds to America/New_York
printf "2\n107\n" | sudo DEBIAN_FRONTEND=noninteractive apt-get install --reinstall tzdata

wget --https-only --secure-protocol=TLSv1_2 --quiet --continue --progress=dot:giga https://tiup-mirrors.pingcap.com/install.sh
sudo chmod +x ./install.sh
./install.sh
PATH="$TIUP_HOME/bin/:$PATH"
export PATH

tiup update --self && tiup update cluster

if [[ $MODE == "tikv" ]]; then
  echo "Running benchmark on TiKV only"
  DB_CONFIG_FILE=./config/tidb-tikv.toml
  NUM_TIFLASH_INSTANCES=0
elif [[ $MODE == "tiflash" ]]; then
  echo "Running benchmark on TiFlash only"
  DB_CONFIG_FILE=./config/tidb-tiflash.toml
  NUM_TIFLASH_INSTANCES=1
fi;

echo "Using configuration file $DB_CONFIG_FILE"
echo "Using $NUM_TIFLASH_INSTANCES TiFlash instances"

nohup tiup playground $TIDBVERSION --db 1 --pd 1 --kv 1 --tiflash $NUM_TIFLASH_INSTANCES --db.config $DB_CONFIG_FILE --without-monitor > tiup-cluster.out 2>&1 &
while [ ! -f tiup-cluster.out ]; do sleep 1; done
# Might take a while because dependencies need to be downloaded
while ! grep -q 'TiDB Playground Cluster is started' tiup-cluster.out; do
  echo "Cluster is not running yet. Checking again in 10 seconds..."
  sleep 10
done

echo "Cluster is running!"
tiup playground display

alias mysql="mysql --host 127.0.0.1 --port 4000 --connect-timeout 10800 -u root"

# Deactivate query plan cache
# For details see https://docs.pingcap.com/tidb/v8.5/sql-non-prepared-plan-cache/
mysql -e "SET GLOBAL tidb_enable_non_prepared_plan_cache = OFF;"

rm -rf $DATA_DIR
mkdir $DATA_DIR
# File name must correspond to <db_name>.<table_name>.<extension>
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz' -O "$DATA_DIR/$DB_NAME.$TABLE_NAME.csv.gz"
gzip -d -f "$DATA_DIR/$DB_NAME.$TABLE_NAME.csv.gz"
chmod 444 "$DATA_DIR/$DB_NAME.$TABLE_NAME.csv"

mysql -e "DROP DATABASE IF EXISTS $DB_NAME;"
mysql -e "CREATE DATABASE $DB_NAME;"
mysql test < create.sql

if [[ $MODE == "tiflash" || $MODE == "tikv-tiflash" ]]; then
  echo "Enabling TiFlash"
  mysql test -e "ALTER TABLE $TABLE_NAME SET TIFLASH REPLICA 1;"
fi;

rm -rf /tmp/sorted-kv-dir
mkdir /tmp/sorted-kv-dir
nohup tiup tidb-lightning -config ./config/tidb-lightning.toml > tiup-tidb-lightning.out 2>&1 &
while [ ! -f tidb-lightning.log ]; do sleep 1; done
echo "Starting to check for completion on $(date +"%T")"
while ! grep -q 'the whole procedure completed' tidb-lightning.log; do
  if grep -q 'tidb lightning exit.*finished=false' tidb-lightning.log || grep -q 'ERROR' tidb-lightning.log; then
    echo "An error occurred during the import. Check the log file for details."
    exit 1
  fi;
  grep 'progress.*total' tidb-lightning.log | tail -n 1
  echo "Data loading is not done yet. Checking again in 10 seconds..."
  sleep 10
done

echo "Data loading is done! Checking log file for time taken to load the data."
grep 'the whole procedure completed' tidb-lightning.log

mysql test -e "ANALYZE TABLE $TABLE_NAME;"

./run.sh 2>&1 | tee log.txt

# Take storage size of TiKV for ALL modes into account, because directly loading data into TiFlash only is currently not supported
echo "Calculating storage size of TiKV in bytes..."
mysql test -e "SELECT (DATA_LENGTH + INDEX_LENGTH) AS TIKV_STORAGE_SIZE_BYTES FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = '$TABLE_NAME';"

if [[ $MODE == "tiflash" || $MODE == "tikv-tiflash" ]]; then
  echo "Calculating additional storage size of TiFlash in bytes..."
  mysql test -e "SELECT TOTAL_SIZE AS TIFLASH_STORAGE_SIZE_BYTES FROM information_schema.tiflash_tables WHERE TIDB_DATABASE = '$DB_NAME' AND TIDB_TABLE = '$TABLE_NAME';"
fi;

grep -P 'rows? in set|Empty set|^ERROR' log.txt |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2) { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
