#!/bin/bash

# Your docker may be set up to use localhost instead, if so
# edit the ip address below.
CONNECTION=postgres://postgres:duckdb@172.17.0.2:5432/postgres
PSQL=psql

DATABASE='ddb$pgclick'
PARQUET_FILE='https:\/\/datasets.clickhouse.com\/hits_compatible\/hits.parquet'

echo "Loading data"
(
	echo "\timing"
	cat create.sql | 
		sed -e "s/REPLACE_DATABASE/$DATABASE/g" -e "s/REPLACE_PARQUET_FILE/$PARQUET_FILE/g" 
) | $PSQL $CONNECTION | grep 'Time'

