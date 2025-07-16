#!/bin/bash

# Set input parameters
PG_USER="$1"
PG_PASSWORD="$2"
HOST_NAME=$3
PORT=$4

DATABASE="hits"

# Install dependencies
sudo yum update -y
sudo yum install postgresql-server -y
sudo yum install postgresql-contrib -y

# Set the file name and download link
FILENAME="hits.tsv"

../lib/download-tsv.sh
chmod 777 ~ hits.tsv

# create database and create table
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d postgres  -t -c "DROP DATABASE IF EXISTS $DATABASE"
sleep 15  # sleep for 15 seconds
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d postgres  -t -c "CREATE DATABASE $DATABASE"
sleep 15  # sleep for 15 seconds
PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD psql -h $HOST_NAME -p $PORT -d $DATABASE -t < create.sql
sleep 15  # sleep for 15 seconds

# split data
echo "Starting to split the file..."
split -l 10000000 hits.tsv hits_part_

# load data
echo "Starting to load data..."
for file in hits_part_*; do
    echo -n "Load time: "
    PGUSER=$PG_USER PGPASSWORD=$PG_PASSWORD command time -f '%e' psql -h $HOST_NAME -p $PORT -d $DATABASE -t -c "\\copy hits FROM '$file'"
done

# run clickbench test with queries
echo "Starting to run queries..."

./run.sh $PG_USER $PG_PASSWORD $HOST_NAME $PORT $DATABASE 2>&1 | tee log_queries_$DATABASE.txt

cat log_queries_$DATABASE.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }' | tee result_queries_$DATABASE.txt
