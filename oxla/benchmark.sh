#!/bin/bash -e

# docker
sudo apt-get install -y docker.io

# base
sudo apt-get install -y postgresql-client curl wget apt-transport-https ca-certificates software-properties-common gnupg2 parallel
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential

# download dataset
echo "Download dataset."
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
echo "Unpack dataset."
pigz -d -f hits.csv.gz
sudo mkdir /data
sudo mv hits.csv /data

# get and configure Oxla image
echo "Install and run Oxla."

docker run --rm -p 5432:5432 -v data:/data --name oxlacontainer public.ecr.aws/oxla/release:1.53.0-beta > /dev/null 2>&1 &

# create table and ingest data
export PGCLIENTENCODING=UTF8

for _ in {1..600}
do
  PGPASSWORD=oxla psql -h localhost -U oxla -t < create.sql && break
  sleep 1
done

echo "Insert data."
echo -n "Load time: "
PGPASSWORD=oxla command time -f '%e' psql -h localhost -U oxla -t -c "COPY hits FROM '/data/hits.csv';"

# get ingested data size
echo -n "Data size: "
PGPASSWORD=oxla psql -h localhost -U oxla -q -t -c "SELECT pg_total_relation_size('hits');"

# run benchmark
echo "running benchmark..."
./run.sh
