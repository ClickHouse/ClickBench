#!/bin/bash

# export OSS_ENDPOINT=..., eg. oss-cn-hangzhou-internal.aliyuncs.com
# export OSS_PATH=..., eg. oss://clickhouse-test-clickbench-hangzhou/clickbench/hits_parquets/
# export AK=...
# export SK=...

mkdir hits_parquets

# Remove existing data packages in the current path and get the latest data from the official website
# rm hits_parquets/*

# Download the latest data package
cd ./hits_parquets
wget https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet 

# Remove historical Clickbench data
# ossutil rm -i $AK -k $SK --endpoint $OSS_ENDPOINT $OSS_PATH

# Upload the latest test dataset package
ossutil cp -r -i $AK -k $SK --endpoint $OSS_ENDPOINT  ./hits_parquets $OSS_PATH
