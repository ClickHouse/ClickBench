#!/bin/bash

# Install
sudo apt-get update -y
sudo apt-get install -y git g++ cmake ninja-build libssl-dev build-essential make ccache pip

# Check libcudf environment
./check_libcudf_env.sh
if [[ $? -ne 0 ]]; then
    echo "libcudf environment check failed. Exiting."
    exit 1
fi

# Build Sirius
git clone --recurse-submodules https://github.com/sirius-db/sirius.git
cd sirius
export SIRIUS_HOME_PATH=`pwd`
cd duckdb
mkdir -p extension_external && cd extension_external
git clone https://github.com/duckdb/substrait.git
cd substrait
git reset --hard ec9f8725df7aa22bae7217ece2f221ac37563da4 #go to the right commit hash for duckdb substrait extension
cd $SIRIUS_HOME_PATH
make -j$(nproc)
export PATH="$PATH:`pwd`/build/release/"
cd ..

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
  awk '{
    buf[i++] = $1
    if (i == 4) {
      printf "[%s,%s,%s],\n", buf[1], buf[2], buf[3]
      i = 0
    }
  }'
