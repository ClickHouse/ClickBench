#!/bin/bash

# Call like
#   ./run-all-benchmarks.sh clickhouse-datalake-partitioned

dir="$1"

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "Usage: $0 <directory>"
  exit 1
fi

# Results live under <dir>/results/<YYYYMMDD>/<machine>.json. Each machine that
# has ever been benchmarked appears under at least one date subdir.
LANG=C ls -1 "$dir"/results/*/*.json 2>/dev/null \
  | awk -F/ '{ print $NF }' \
  | sort -u \
  | while read -r filename; do
  machine="${filename%.*}"

  echo '-----------------------------------------'
  export system=$dir machine=$machine
  ./run-benchmark.sh
done
