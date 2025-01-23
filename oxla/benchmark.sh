#!/bin/bash -e

# docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce

# base
sudo apt-get install -y postgresql-client curl wget apt-transport-https ca-certificates software-properties-common gnupg2 parallel
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential

# download dataset
echo "Download dataset."
wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
echo "Unpack dataset."
gzip -d hits.csv.gz
chmod 777 ~ hits.csv
mkdir ~/data
mv hits.csv ~/data

# get and configure Oxla image
echo "Install and run Oxla."

sudo docker run --rm -p 5432:5432 -v ~/data:/data --name oxlacontainer public.ecr.aws/oxla/release:1.53.0-beta > /dev/null 2>&1 &
sleep 30 # waiting for container start and db initialisation (leader election, etc.)

# create table and ingest data
export PGCLIENTENCODING=UTF8

PGPASSWORD=oxla psql -h localhost -U oxla -t < create.sql
echo "Insert data."
PGPASSWORD=oxla psql -h localhost -U oxla -t -c '\timing' -c "COPY hits FROM '/data/hits.csv';"

# get ingested data size
echo "data size after ingest:"
PGPASSWORD=oxla psql -h localhost -U oxla -t -c '\timing' -c "SELECT pg_total_relation_size('hits');"

# wait for merges to finish
sleep 60

# run benchmark
echo "running benchmark..."
./run.sh