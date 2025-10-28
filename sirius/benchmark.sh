#!/bin/bash

# Install dependencies
source dependencies.sh

# Build Sirius
git clone --recurse-submodules https://github.com/sirius-db/sirius.git
cd sirius
source setup_sirius.sh
make -j$(nproc)
export PATH="$PATH:`pwd`/build/release/"
cd ..

# Load the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

echo -n "Load time: "
command time -f '%e' duckdb hits.db -f create.sql -f load.sql

# Run the queries

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
wc -c hits.db

cat log.txt |
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' |
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' |
  awk '{
    buf[i++] = $1
    if (i == 4) {
      printf "[%s,%s,%s],\n", buf[1], buf[2], buf[3]
      i = 0
    }
  }'
