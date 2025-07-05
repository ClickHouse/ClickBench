#!/bin/bash

# Install
sudo apt-get update
sudo apt-get install ninja-build cmake build-essential make ccache pip clang pkg-config -y

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
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --progress=dot:giga https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Convert parquet files to vortex partitioned
seq 0 99 | xargs -P"$(nproc)" -I{} bash -c '
  if [ ! -f "hits_{}.vortex" ]; then
    echo -n "Load time: "
    command time -f '%e' -c "COPY 'hits_{}.parquet' TO hits_{}.vortex (FORMAT vortex)"
  fi
'

# Convert parquet files to vortex single
if [ ! -f "hits.vortex" ]; then
  echo -n "Load time: "
  command time -f '%e' -c "COPY 'hits_*.parquet' TO hits.vortex (FORMAT vortex)"
fi

echo -n "Load time: "
command time -f '%e' duckdb hits-partitioned.db -c "CREATE VIEW hits AS SELECT * FROM read_vortex('hits_*.vortex')";

echo -n "Load time: "
command time -f '%e' duckdb hits-single.db -c "CREATE VIEW hits AS SELECT * FROM read_vortex('hits.vortex')";



# Run the queries
echo 'partitioned'

./run.sh 'hits-partitioned.db' 2>&1 | tee log-p.txt
cat log-p.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo ''
echo 'single'

./run.sh 'hits-single.db' 2>&1 | tee log-s.txt
cat log-s.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
