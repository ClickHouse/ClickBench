#!/bin/bash
# Run the benchmark for both Athena entries (single file, then partitioned)
# and write their results JSONs. Each log goes to log.txt in its entry.
set -u
cd "$(dirname "$0")"
date=$(date +%F)
for entry in athena athena-partitioned; do
    echo "=== $entry"
    (cd "../$entry" && ./benchmark.sh > log.txt 2>&1; ./make-result log.txt "$date") \
        || echo "$entry failed; see ../$entry/log.txt"
done
