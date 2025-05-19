#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install ninja-build cmake build-essential make ccache pip clang -y

export CC=clang
export CXX=clang++
git clone https://github.com/vortex-data/vortex --recursive
cd vortex/duckdb-vortex
git checkout v0.34.0
GEN=ninja NATIVE_ARCH=1 LTO=thin make
export PATH="`pwd`/build/release/:$PATH"
cd ../..

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

seq 0 99 | xargs -P100 -I{} bash -c 'duckdb -c "COPY "hits_{}.parquet" TO hits_{}.vortex (FORMAT vortex)" '

time duckdb hits.db -f create.sql

# Run the queries

./run.sh 2>&1 | tee log.txt

wc -c hits.db

cat log.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
