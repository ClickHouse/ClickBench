#!/bin/bash -e

sudo apt-get update -y
sudo apt-get install -y openjdk-11-jdk
sudo update-alternatives --config java

# On small machines it can only work with swap
sudo fallocate -l 200G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Install

VERSION=33.0.0

wget -O"apache-druid-${VERSION}-bin.tar.gz" "https://dlcdn.apache.org/druid/${VERSION}/apache-druid-${VERSION}-bin.tar.gz"
tar xf apache-druid-${VERSION}-bin.tar.gz
./apache-druid-${VERSION}/bin/verify-java

# Have to increase indexer memory limit
sed -i 's MaxDirectMemorySize=1g MaxDirectMemorySize=5g g' apache-druid-$VERSION/conf/druid/single-server/medium/middleManager/runtime.properties

# Disable cache to test query performance
sed -i 's druid.historical.cache.useCache=true druid.historical.cache.useCache=false g' apache-druid-$VERSION/conf/druid/single-server/medium/historical/runtime.properties
sed -i 's druid.historical.cache.populateCache=true druid.historical.cache.populateCache=false g' apache-druid-$VERSION/conf/druid/single-server/medium/historical/runtime.properties
sed -i 's druid.processing.buffer.sizeBytes=500MiB druid.processing.buffer.sizeBytes=1000MiB g' apache-druid-$VERSION/conf/druid/single-server/medium/historical/runtime.properties

echo "druid.query.groupBy.maxMergingDictionarySize=5000000000" >> apache-druid-$VERSION/conf/druid/single-server/medium/historical/runtime.properties
# Druid launcher does not start Druid as a daemon. Run it in background
./apache-druid-${VERSION}/bin/start-single-server-medium &

# Load the data

../lib/download-tsv.sh

echo -n "Load time: "
command time -f '%e' ./apache-druid-${VERSION}/bin/post-index-task --file ingest.json --url http://localhost:8081

# The command above will fail due to timeout but still continue to run in background.
# The loading time should be checked from the logs.

# Run the queries
./run.sh

# stop Druid services
kill %1

echo -n "Data size: "
du -bcs ./apache-druid-${VERSION}/var | grep total
