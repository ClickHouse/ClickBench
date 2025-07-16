#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y openjdk-11-jdk jq
sudo update-alternatives --config java

# Install

PINOT_VERSION=1.3.0

wget --continue --progress=dot:giga https://downloads.apache.org/pinot/apache-pinot-$PINOT_VERSION/apache-pinot-$PINOT_VERSION-bin.tar.gz
tar -zxvf apache-pinot-$PINOT_VERSION-bin.tar.gz

./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh QuickStart -type batch &
sleep 30
./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh AddTable -tableConfigFile offline_table.json -schemaFile schema.json -exec

# Load the data

../lib/download-tsv.sh

# Pinot was unable to load data as a single file wihout any errors returned. We have to split the data
echo -n "Load time: "
command time -f '%e' split -d --additional-suffix .tsv -n l/100 hits.tsv parts

# Pinot can't load value '"tatuirovarki_redmond' so we need to fix this row to make it work
echo -n "Load time: "
command time -f '%e' sed parts93.tsv -e 's/"tatuirovarki_redmond/tatuirovarki_redmond/g' -i

# Fix path to local directory
sed splitted.yaml 's/PWD_DIR_PLACEHOLDER/'$PWD'/g' -i
sed local.yaml 's/PWD_DIR_PLACEHOLDER/'$PWD'/g' -i

# Load data
echo -n "Load time: "
command time -f '%e' ./apache-pinot-$PINOT_VERSION-bin/bin/pinot-admin.sh LaunchDataIngestionJob -jobSpecFile splitted.yaml

# After upload it shows 94465149 rows instead of 99997497 in the dataset

# Run the queries
./run.sh

# stop Pinot services
kill %1

echo -n "Data size: "
du -bcs ./batch | grep total
