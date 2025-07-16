#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y ninja-build cmake build-essential make ccache pip clang

export CC=clang
export CXX=clang++
git clone https://github.com/duckdb/duckdb
cd duckdb
git checkout v1.3-ossivalis
LATEST_STORAGE=1 GEN=ninja NATIVE_ARCH=1 LTO=thin make
export PATH="$PATH:`pwd`/build/release/"
cd ..

# Load the data
../lib/download-tsv.sh

echo -n "Load time: "
command time -f '%e' duckdb hits.db -f create.sql -c "COPY hits FROM 'hits.tsv' (QUOTE '')"

# Run the queries

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
wc -c hits.db

cat log.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
