#!/usr/bin/bash

# Run setup.sh (assume we are running on ubuntu)
./setup-dev-ubuntu.sh

# On small machines it can only work with swap
sudo fallocate -l 200G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# download the db
export KINETICA_ADMIN_PASSWORD=admin
curl https://files.kinetica.com/install/kinetica.sh -o kinetica && chmod u+x kinetica && sudo -E ./kinetica start

# set up the cli
wget --continue --progress=dot:giga https://github.com/kineticadb/kisql/releases/download/v7.1.7.2/kisql

chmod u+x ./kisql

export KI_PWD="admin"
CLI="./kisql --host localhost --user admin"

# download the ds
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
sudo mv hits.tsv.gz ./kinetica-persist/

$CLI --file create.sql
$CLI --sql "ALTER TIER ram WITH OPTIONS ('capacity' = '27000000000');"

START=$(date +%s)

$CLI --sql "load into hits from file paths 'hits.tsv.gz' format delimited text (INCLUDES HEADER=false, DELIMITER = '\t') WITH OPTIONS (NUM_TASKS_PER_RANK=16, ON ERROR=SKIP);"

END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load time: $LOADTIME"
echo "Data size: $(du -bcs ./kinetica-persist/gpudb | grep total)"

# run the queries
./run.sh
