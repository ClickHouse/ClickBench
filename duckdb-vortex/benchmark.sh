#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y ninja-build cmake build-essential make ccache pip clang pkg-config

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path

export CC=clang
export CXX=clang++
git clone https://github.com/vortex-data/vortex --recursive
cd vortex/duckdb-vortex
git checkout 0.35.0
GEN=ninja NATIVE_ARCH=1 LTO=thin make
export PATH="`pwd`/build/release/:$PATH"
cd ../..

# Load the data
wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Convert parquet files to vortex partitioned
echo -n "Load time: "
command time -f '%e' duckdb -c "COPY 'hits.parquet' TO hits.vortex (FORMAT vortex)"

echo -n "Load time: "
command time -f '%e' duckdb hits-single.db -c "CREATE VIEW hits AS SELECT * FROM read_vortex('hits.vortex')";

echo 'single'

./run.sh 'hits-single.db' 2>&1 | tee log-s.txt
cat log-s.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.vortex)"
