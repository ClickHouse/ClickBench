#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install ninja-build cmake build-essential make ccache pip clang pkg-config -y

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path

export CC=clang
export CXX=clang++
git clone https://github.com/vortex-data/vortex --recursive
cd vortex/duckdb-vortex
git checkout 0.34.0
GEN=ninja NATIVE_ARCH=1 LTO=thin make
export PATH="`pwd`/build/release/:$PATH"
cd ../..

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue https://pub-3ba949c0f0354ac18db1f0f14f0a2c52.r2.dev/clickbench/parquet_many/hits_{}.parquet'

# Convert parquet files to vortex
seq 0 99 | xargs -P"$(nproc)" -I{} bash -c '
  if [ ! -f "hits_{}.vortex" ]; then
    duckdb -c "COPY 'hits_{}.parquet' TO hits_{}.vortex (FORMAT vortex)"
  fi
'

time duckdb hits.db -f create.sql

# Run the queries

./run.sh 2>&1 | tee log.txt

wc -c hits.db

cat log.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
