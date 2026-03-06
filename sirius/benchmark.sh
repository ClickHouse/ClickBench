#!/bin/bash

# Install dependencies (ensure the filename matches your setup script)
source dependencies.sh

# Ensure Pixi is in the PATH for the current script
export PATH="$HOME/.pixi/bin:$PATH"

# Clean up any broken previous runs
rm -rf sirius

# Build Sirius from your optimized fork
git clone --recurse-submodules -b clickbench https://github.com/sirius-db/sirius.git
cd sirius

# Enable strict error checking: fail immediately if the build crashes
set -e

# Set up the substrait extension as an external extension (required by sirius)
mkdir -p duckdb/extension_external
git clone https://github.com/duckdb/substrait.git duckdb/extension_external/substrait
git -C duckdb/extension_external/substrait reset --hard ec9f8725df7aa22bae7217ece2f221ac37563da4

# Install the pixi environment first so the prefix path exists
pixi install

# LIBCUDF_ENV_PREFIX must be set before cmake runs (CMakeLists.txt checks it at configure time)
export LIBCUDF_ENV_PREFIX="$(pwd)/.pixi/envs/default"

# Execute the build process inside the isolated Pixi environment
pixi run make -j$(nproc)

# Inject the Pixi environment variables into the current bash session
eval "$(pixi shell-hook)"

# Add the compiled duckdb binary to the PATH
export PATH="$(pwd)/build/release/:$PATH"

# Return to the parent directory
cd ..

# Turn strict error checking back off for the benchmark phase
set +e

# Load the data
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

echo -n "Load time: "
command time -f '%e' duckdb hits.db -f create.sql -f load.sql

# Run the queries
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
wc -c hits.db

cat log.txt | \
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' | \
  sed -r -e 's/^.*(Killed|Segmentation).*$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' | \
  awk '{
    buf[i++] = $1
    if (i == 4) {
      printf "[%s,%s,%s],\n", buf[1], buf[2], buf[3]
      i = 0
    }
  }'
