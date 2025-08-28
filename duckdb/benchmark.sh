#!/bin/bash

# Install
curl https://install.duckdb.org | sh
export PATH='~/.duckdb/cli/latest':$PATH

# Load the data
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

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
