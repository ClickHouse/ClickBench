#!/bin/bash

# Remove existing data packages in the current path and get the latest data from the official website
rm hits_parquets/*

# Download the latest data package
cd ./hits_parquets
wget https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet 

# Remove historical Clickbench data
ossutil rm -i $AK -k $SK --endpoint oss-ap-southeast-1.aliyuncs.com oss://clickhouse-test-clickbench-apsoutheast-1/clickbench/

# Upload the latest test dataset package
ossutil cp -r -i $AK -k $SK --endpoint oss-ap-southeast-1.aliyuncs.com  ./hits_parquets oss://clickhouse-test-clickbench-apsoutheast-1/clickbench/hits_parquets/

# OSS automatically synchronizes data to Hangzhou