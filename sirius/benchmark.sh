#!/bin/bash
# ClickBench benchmark for Sirius (GPU-accelerated DuckDB extension)
#
# Usage: ./benchmark.sh
# Prerequisites: NVIDIA GPU with CUDA driver, internet access

source dependencies.sh

# Verify pixi is available
if ! command -v pixi &> /dev/null; then
  echo "Error: pixi not found. Check dependencies.sh output."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Build Sirius
# ---------------------------------------------------------------------------
rm -rf sirius
git clone --recurse-submodules https://github.com/sirius-db/sirius.git
cd sirius

set -e

pixi install
export LIBCUDF_ENV_PREFIX="$(pwd)/.pixi/envs/default"
pixi run make -j"$(nproc)"

# Make the build artifacts available
eval "$(pixi shell-hook)"
export PATH="$(pwd)/build/release:$PATH"
cd ..

set +e

# ---------------------------------------------------------------------------
# 2. Load data
# ---------------------------------------------------------------------------
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

echo -n "Load time: "
command time -f '%e' duckdb hits.db -f create.sql -f load.sql

# ---------------------------------------------------------------------------
# 3. Run benchmark
# ---------------------------------------------------------------------------
./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
wc -c hits.db

# ---------------------------------------------------------------------------
# 4. Format results
# ---------------------------------------------------------------------------
cat log.txt | \
  grep -P '^\d|Killed|Segmentation|^Run Time \(s\): real' | \
  sed -r -e 's/^.(Killed|Segmentation).$/null\nnull\nnull/; s/^Run Time \(s\): real\s*([0-9.]+).*$/\1/' | \
  awk '{
    buf[i++] = $1
    if (i == 4) {
      printf "[%s,%s,%s],\n", buf[1], buf[2], buf[3]
      i = 0
    }
  }'