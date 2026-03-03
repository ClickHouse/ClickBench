#!/bin/bash

# Call like
#   ./run-all-benchmarks.sh clickhouse-datalake-partitioned

dir="$1"

if [[ -z "$dir" || ! -d "$dir" ]]; then
  echo "Usage: $0 <directory>"
  exit 1
fi

for file in "$1"/results/*; do
  [ -e "$file" ] || continue

  filename="$(basename "$file")"
  machine="${filename%.*}"


  echo '-----------------------------------------'
  ./run-benchmark.sh "$machine" "$dir"
done

