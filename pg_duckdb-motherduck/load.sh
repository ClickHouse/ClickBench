#!/bin/bash

CONNECTION=postgres://postgres:duckdb@localhost:5432/postgres
PSQL=psql

DATABASE='ddb$pgclick'
PARQUET_FILE='https:\/\/datasets.clickhouse.com\/hits_compatible\/hits.parquet'

echo "Loading data"
(
	echo "\timing"
	cat create.sql | 
		sed -e "s/REPLACE_SCHEMA/$DATABASE/g" -e "s/REPLACE_PARQUET_FILE/$PARQUET_FILE/g" 
) | $PSQL $CONNECTION | grep 'Time'

