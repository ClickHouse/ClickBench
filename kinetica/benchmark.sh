#!/usr/bin/bash

# download the db
export KINETICA_ADMIN_PASSWORD=admin
curl https://files.kinetica.com/install/kinetica.sh -o kinetica && chmod u+x kinetica && ./kinetica start

# set up the cli
wget https://github.com/kineticadb/kisql/releases/download/v7.1.7.2/kisql

chmod u+x ./kisql

export KI_PWD=admin
CLI="./kisql --host localhost --user admin"

# download the ds
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
gzip -d hits.csv.gz

# prepare the ds for ingestion; bigger files cause out of memory error
split -a 2 -d -l 5000000 hits.csv hits_part_

# create the table
$CLI --file create.sql

# ingest data
input_files=$(find -type f -name 'hits_part_*' 2> /dev/null)

START=$(date +%s)

for f in $input_files
do
    $CLI --sql "upload files '$f' into '~admin';"
    $CLI --sql "load into hits from file paths 'kifs://~admin/$f' format delimited text (INCLUDES HEADER=false) WITH OPTIONS (ON ERROR=SKIP);"
done

END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load time is $LOADTIME seconds"

# run the queries
./run.sh
