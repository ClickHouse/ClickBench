#!/bin/bash
# Turns a finished run into results/<YYYYMMDD>/<machine>.json.
#
#   ./benchmark.sh
#   ./make-json.sh c6a.4xlarge
#
# The per-try timings come from result.csv, which the driver writes as
# <query>,<try>,<seconds>; the metadata comes from template.json. The table
# adopts the downloaded parquet in place, so the load is a catalog write and
# the data size is the file's own.
set -eu

machine=${1:?usage: $0 <machine>}
date=$(date -u +%Y-%m-%d)
output="results/${date//-/}/$machine.json"

mkdir -p "$(dirname "$output")"
jq -n \
    --slurpfile template template.json \
    --arg date "$date" \
    --arg machine "$machine" \
    --rawfile csv result.csv \
    '$template[0] + {
        date: $date,
        machine: $machine,
        cluster_size: 1,
        load_time: 0,
        data_size: 14779976446,
        result: ($csv | split("\n") | map(select(length > 0) | split(","))
                 | group_by(.[0] | tonumber) | sort_by(.[0][0] | tonumber)
                 | map(map(.[2] | if . == "null" then null else tonumber end)))
    }' > "$output"
echo "$output"
