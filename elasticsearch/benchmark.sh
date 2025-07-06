#!/bin/bash

# Install prerequisite packages
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates wget

# Add Elastic's signing key
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-8.x.list

# Update package list and install
sudo apt-get update -y
sudo apt-get install -y elasticsearch

sudo /bin/systemctl daemon-reload
sudo /bin/systemctl enable elasticsearch.service
sudo systemctl start elasticsearch.service

# Reset password
sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic

# Set password in terminal for future use
export PASSWORD='...'

# Check Elasticsearch is alive - you should get a JSON response
curl -k -XGET 'https://localhost:9200' -u "elastic:${PASSWORD}"


###### Create index with mappings mirroring data types in ClickHouse

# Note: Field types were mapped as closely as possible to https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql I chose "keyword" because queries are not taking advantage of freetext search.

# Note: Elasticsearch does not have the concept of a primary key, but it does have an "index sorting" feature, which is intended to help in analytical use cases where sort order on disk matters. I set it to the same parameters as primary key for the ClickHouse tests https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql

curl -k -X PUT "https://localhost:9200/hits?pretty" -u "elastic:${PASSWORD}"  -H 'Content-Type: application/json' -d @mapping.json


###### Data loading (JSON dump via ES Bulk API insert)

# Download and unzip dataset
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'
pigz -d -f hits.json.gz

# Prepare Elasticsearch for large bulk insert. To do the large upload, you have to break up JSON file into smaller files to prevent 'curl' from OOM while doing it, and adjust ELasticsearch HTTP upload size minimum. This creates roughly 250M files (note it takes a while)
split -l 10000000 hits.json hits_

# Modify Elasticsearch settings to accept it (default is 100M bulk API uploads)
echo "http.max_content_length: 500mb" >> /etc/elasticsearch/elasticsearch.yml
sudo systemctl restart elasticsearch.service

# Re-format and import all the small JSON files sequentially

# command to split the files - process above can take hours, so better run in background and disown
for file in hits_*; do sed -e 's/^/{ "index" : { "_index" : "hits"} }\n/' -i ${file}; done

# command to load data into ES - process above can take hours, so better run in background and disown
for file in hits_*; do echo -n "Load time: "
    command time -f '%e' curl -s -o /dev/null -H "Content-Type: application/x-ndjson" -k -XPOST -u "elastic:${PASSWORD}" "https://localhost:9200/_bulk" --data-binary @${file}; done

# check on progress
curl -k -X GET "https://localhost:9200/hits/_stats/docs?pretty" -u "elastic:${PASSWORD}"

# when data loading is finished, to get all stats run
# For Load time, look at: bulk.total_time_in_millis
# For Data size, look at: store.total_data_set_size_in_bytes
curl -k -X GET "https://localhost:9200/hits/_stats?pretty" -u "elastic:${PASSWORD}"


######  Run the queries
./run.sh
