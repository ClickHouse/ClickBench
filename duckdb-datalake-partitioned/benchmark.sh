#!/bin/bash

# Install
export HOME=${HOME:=~}
curl https://install.duckdb.org | sh
export PATH=$HOME'/.duckdb/cli/latest':$PATH

echo -n "Load time: "
command time -f '%e' duckdb hits.db -f create.sql

echo "Data size: 14737666736"

# Run the queries

./run.sh 2>&1 | tee log.txt

wc -c hits.db

cat log.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
