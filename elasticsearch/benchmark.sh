#!/bin/bash

# Install prerequisite packages
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates wget gpg time jq bc

# Add Elastic's signing key
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

# Add the repository for version 9.x
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-9.x.list

# Update package list and install
sudo apt-get update -y
sudo apt-get install -y elasticsearch

sudo /bin/systemctl daemon-reload
sudo /bin/systemctl enable elasticsearch.service
sudo systemctl start elasticsearch.service

# Disable security (all other are default configs)
cat << EOF > elasticsearch.yml
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

# Disable security features
xpack.security.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

cluster.initial_master_nodes: ["clickbench"]
http.host: 0.0.0.0
EOF

sudo cp elasticsearch.yml /etc/elasticsearch/elasticsearch.yml

# Restart Elasticsearch with the updated configs
sudo systemctl restart elasticsearch.service


# Check Elasticsearch is alive - you should get a JSON response
curl -sS -X GET 'http://localhost:9200'


###### Create index with mappings mirroring data types in ClickHouse

# Note: Field types were mapped as closely as possible to https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql I chose "keyword" because queries are not taking advantage of freetext search.

# Note: Elasticsearch does not have the concept of a primary key, but it does have an "index sorting" feature, which is intended to help in analytical use cases where sort order on disk matters. I set it to the same parameters as primary key for the ClickHouse tests https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql

curl -sS -X PUT "http://localhost:9200/hits?pretty" -H 'Content-Type: application/json' -d @mapping.json


###### Data loading (JSON dump via ES Bulk API insert)

# Download the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'

START=$(date +%s)

# Reads and loads all the data into Elasticsearch
python3 load.py

# check on progress
curl -sS -X GET "http://localhost:9200/hits/_stats/docs?pretty"

# Makes sure all data is flushed to disk
curl -sS -X GET "http://localhost:9200/_flush?pretty"

# when data loading is finished, to get all stats run
# For Load time, look at: bulk.total_time_in_millis
# For Data size, look at: store.total_data_set_size_in_bytes
curl -sS -X GET "http://localhost:9200/hits/_stats?pretty" | tee stats.json
echo "Data size: $(jq -r '._all.total.store.total_data_set_size_in_bytes' stats.json)"

END=$(date +%s)
echo "Load time: $(echo "$END - $START" | bc)"

######  Run the queries
./run.sh
