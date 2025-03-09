#!/bin/bash

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/
# It requires Ubuntu 20.04. The latest version 22.04 would not work.

wget -qO - https://www.mongodb.org/static/pgp/server-6.0.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/6.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-6.0.list
sudo apt-get update
sudo apt-get install -y mongodb-org
sudo systemctl start mongod
sudo systemctl status mongod

#################################
# set params `internalQueryPlannerGenerateCoveredWholeIndexScans` to true because we know that collscan is
# always bad. Decision about enabling should be made if collection data couldn't fit to RAM.
# NOTE: This option is reset to default on restart until it saved in mongo config file.
#       Don't forget to set again if mongo restart needed or crashes happened while queries run and
#       you want to continue theirs execution.
time mongosh --quiet --eval 'db.adminCommand({setParameter: 1,"internalQueryPlannerGenerateCoveredWholeIndexScans": true});'


#################################
# Create the indexes before import data because each index is reread all data
# Q6
time mongosh --quiet --eval 'db.hits.createIndex({"EventDate": 1});'
# Q10, Q11
time mongosh --quiet --eval 'db.hits.createIndex({"MobilePhoneModel": 1});'
# Q28
time mongosh --quiet --eval 'db.hits.createIndex({"Referer": 1});'
# Q40
time mongosh --quiet --eval 'db.hits.createIndex({"RefererHash": 1});'
# Q41
time mongosh --quiet --eval 'db.hits.createIndex({"URLHash": 1});'
# Q3, Q4, Q15, Q19
time mongosh --quiet --eval 'db.hits.createIndex({"UserID": 1});'
# Q1, Q2, Q7, Q9
time mongosh --quiet --eval 'db.hits.createIndex({"AdvEngineID": 1, "ResolutionWidth": 1, "RegionID": 1});'
# Q8
time mongosh --quiet --eval 'db.hits.createIndex({"RegionID": 1, "UserID": 1});'
# Q5, Q12, Q14, Q24, Q30, Q31
time mongosh --quiet --eval 'db.hits.createIndex({"SearchPhrase": 1, "SearchEngineID": 1});'
# Q13, Q16, Q17, Q18, Q26
time mongosh --quiet --eval 'db.hits.createIndex({"SearchPhrase": 1, "UserID": 1, "EventTime": 1});'
# Q21, Q22
time mongosh --quiet --eval 'db.hits.createIndex({"SearchPhrase": 1, "URL": 1, "Title": 1});'
# Q38, Q39
time mongosh --quiet --eval 'db.hits.createIndex({"CounterID": 1, "EventDate": 1, "URL": 1});'
# Q36, Q37, Q42
time mongosh --quiet --eval 'db.hits.createIndex({"CounterID": 1, "IsRefresh": 1, "EventDate": 1});'
# Q20, Q23, Q27, Q33, Q34
time mongosh --quiet --eval 'db.hits.createIndex({"URL": 1, "CounterID": 1 });'
# Q29, Q32, Q35
time mongosh --quiet --eval 'db.hits.createIndex({"ClientIP": 1, "WatchID": 1, "ResolutionWidth": 1, "IsRefresh": 1});'


#################################
# Load data and import
wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

# Use mongo import to load data into mongo. By default numInsertionWorkers is 1 so change to half of VM where it would be run
#time mongoimport --collection hits --type tsv hits.tsv --fieldFile=create.txt --columnsHaveTypes --numInsertionWorkers=8

# But on the AWS c6a.4xlarge machines, parallel import is slower than single-threaded, so we choose the single-threaded import.
time mongoimport --collection hits --type tsv hits.tsv --fieldFile=create.txt --columnsHaveTypes

sudo du -bcs /var/lib/mongodb/
# total size:   82937405440 (77.2 Gb)
# indexes size: 38326390784 (35.6 Gb) // heh, so much but indexes should be
# storage size: 44610863104 (41.5 Gb)

# MongoDB does not support SQL in self-hosted option. Only with MongoDB Atlas service.

time mongosh --quiet ./run.js > result.json
