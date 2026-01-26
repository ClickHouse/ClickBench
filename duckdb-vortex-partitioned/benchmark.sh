#!/bin/bash

set -Eeuo pipefail

# Install
export HOME=${HOME:=~}
curl https://install.duckdb.org | sh
export PATH=$HOME'/.duckdb/cli/latest':$PATH

duckdb -c "INSTALL vortex;"

# Load the data
seq 0 99 | xargs -P100 -I{} bash -c 'wget --continue --quiet https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{}.parquet'

# Convert parquet files to vortex partitioned
echo -n "Load time: "
seq 0 99 | command time -f '%e' xargs -P"$(nproc)" -I{} bash -c '
  if [ ! -f "hits_{}.vortex" ]; then
    duckdb -c "LOAD vortex;" -c "COPY (SELECT * REPLACE (URL::VARCHAR AS URL, Title::VARCHAR AS Title, Referer::VARCHAR AS Referer) FROM '"'"'hits_{}.parquet'"'"') TO '"'"'hits_{}.vortex'"'"' (FORMAT vortex);"
  fi
'

# Create view and macro
echo -n "Load time: "
command time -f '%e' duckdb hits-partitioned.db -f create.sql

# Run the queries
echo 'partitioned'

./run.sh 'hits-partitioned.db' 2>&1 | tee log-p.txt
cat log-p.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'

echo "Data size: $(du -bcs hits_*.vortex | grep total)"
