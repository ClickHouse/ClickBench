#!/bin/bash

set -Eeuo pipefail

# Install
export HOME=${HOME:=~}
curl https://install.duckdb.org | sh
export PATH=$HOME'/.duckdb/cli/latest':$PATH

duckdb -c "INSTALL vortex;"

# Load the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Convert parquet files to Vortex
echo -n "Load time: "
command time -f '%e' duckdb -c "LOAD vortex; COPY 'hits.parquet' TO 'hits.vortex' (FORMAT vortex);"

# Create view and macro
echo -n "Load time: "
command time -f '%e' duckdb hits-single.db -f create.sql

echo 'single'

./run.sh 'hits-single.db' 2>&1 | tee log-s.txt
cat log-s.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -b hits.vortex)"
