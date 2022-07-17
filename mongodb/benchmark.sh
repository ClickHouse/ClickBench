#!/bin/bash

# https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/
# It requires Ubuntu 20.04. The latest version 22.04 would not work.

wget -qO - https://www.mongodb.org/static/pgp/server-5.0.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu focal/mongodb-org/5.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-5.0.list
sudo apt-get update
sudo apt-get install -y mongodb-org
sudo systemctl start mongod
sudo systemctl status mongod

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'
gzip -d hits.json.gz

time mongoimport --collection hits --type json hits.json

# 2022-07-16T00:06:36.161+0000    99997497 document(s) imported successfully. 0 document(s) failed to import.
# real    101m35.264s

# Create the index:
time mongosh --eval 'db.hits.createIndex({"CounterID": 1, "EventDate": 1, "UserID": 1, "EventTime": 1, "WatchID": 1});'
# real    16m38.160s

sudo du -bcs /var/lib/mongodb/
# 54587120319

# MongoDB does not support SQL in self-hosted option. Only with MongoDB Atlas service.

# db.hits.stats().count
#
