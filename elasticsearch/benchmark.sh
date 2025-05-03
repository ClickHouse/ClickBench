#!/bin/bash

###### Set up Elasticsearch

# Follow:
# https://www.elastic.co/guide/en/elasticsearch/reference/current/rpm.html
# https://www.elastic.co/guide/en/elasticsearch/reference/current/starting-elasticsearch.html#start-rpm

sudo rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

sudo vim /etc/zypp/repos.d/elasticsearch.repo
# Add Elasticsearch repo information per documentation https://www.elastic.co/guide/en/elasticsearch/reference/current/rpm.html

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
wget https://datasets.clickhouse.com/hits_compatible/hits.json.gz
gzip -d -f hits.json.gz 

# Prepare Elasticsearch for large bulk insert. To do the large upload, you have to break up JSON file into smaller files to prevent 'curl' from OOM while doing it, and adjust ELasticsearch HTTP upload size minimum. This creates roughly 250M files (note it takes a while)
split -l 10000000 hits.json hits_

# You need to modify Elasticsearch settings to accept it (default is 100M bulk API uploads)
sudo vim /etc/elasticsearch/elasticsearch.yml
# Add "http.max_content_length: 500mb" to the Network Settings section, leaving some buffer for additional commands for bulk import
# Save file, restart Elasticsearch server
sudo systemctl restart elasticsearch.service

# Re-format and import all the small JSON files sequentially

# command to split the files - process above can take hours, so better run in background and disown
for file in hits_*; do sed -e 's/^/{ "index" : { "_index" : "hits"} }\n/' -i ${file}; done

# command to load data into ES - process above can take hours, so better run in background and disown
time for file in hits_*; do curl -s -o /dev/null -H "Content-Type: application/x-ndjson" -k -XPOST -u "elastic:${PASSWORD}" "https://localhost:9200/_bulk" --data-binary @${file}; done

# check on progress
curl -k -X GET "https://localhost:9200/hits/_stats/docs?pretty" -u "elastic:${PASSWORD}"

# when data loading is finished, to get all stats run
# For Load time, look at: bulk.total_time_in_millis
# For Data size, look at: store.total_data_set_size_in_bytes
curl -k -X GET "https://localhost:9200/hits/_stats?pretty" -u "elastic:${PASSWORD}"


######  Run the queries
./run.sh
