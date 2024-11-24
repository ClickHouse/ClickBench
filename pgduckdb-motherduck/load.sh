#!/bin/bash

CONNECTION=postgres://postgres:duckdb@172.17.0.2:5432/postgres
PSQL=psql

USE_MOTHERDUCK=1

if [[ $USE_MOTHERDUCK == 1 ]]; then
DATABASE='ddb$pgclick'
PARQUET_FILE='https:\/\/datasets.clickhouse.com\/hits_compatible\/hits.parquet'
else
DATABASE=temp
PARQUET_FILE='\/tmp\/hits.parquet'
fi

echo "Loading data"
(
	echo "\timing"
	cat create.sql | 
		sed -e "s/REPLACE_DATABASE/$DATABASE/g" -e "s/REPLACE_PARQUET_FILE/$PARQUET_FILE/g" 
) | $PSQL $CONNECTION | grep 'Time'

