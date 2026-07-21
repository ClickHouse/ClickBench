#!/bin/bash

# This script converts the raw `result.csv` data from `benchmark.sh` into the
# final json format used by the benchmark dashboard.
#
# usage : ./make-json.sh <machine>
#
# example (save results/<YYYYMMDD>/c6a.4xlarge.json)
#         ./make-json.sh c6a.4xlarge

MACHINE=$1
DATE=$(date -u +%Y-%m-%d)
YYYYMMDD=${DATE//-/}
mkdir -p "results/${YYYYMMDD}"
OUTPUT_FILE="results/${YYYYMMDD}/${MACHINE}.json"
SYSTEM_NAME="DataFusion (Vortex, partitioned)"
LOAD_TIME=${LOAD_TIME:-null}
DATA_SIZE=${DATA_SIZE:-$(./data-size 2>/dev/null || echo null)}
DATA_SIZE=${DATA_SIZE:-null}

# Read the CSV and build the result array using sed
RESULT_ARRAY=$(awk -F, '{arr[$1]=arr[$1]","$3} END {for (i=1;i<=length(arr);i++) {gsub(/^,/, "", arr[i]); printf "        ["arr[i]"]"; if (i<length(arr)) printf ",\n"}}' result.csv)

# form the final JSON structure from the template
cat <<EOF > $OUTPUT_FILE
{
    "system": "$SYSTEM_NAME",
    "date": "$DATE",
    "machine": "$MACHINE",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "hardware": "cpu",
    "tags": ["Rust","column-oriented","embedded","stateless"],
    "load_time": $LOAD_TIME,
    "data_size": $DATA_SIZE,
    "result": [
        $RESULT_ARRAY
    ]
}
EOF
