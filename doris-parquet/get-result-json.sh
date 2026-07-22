#!/bin/bash

# set -x
DATE=$(date -u +%Y-%m-%d)
YYYYMMDD=${DATE//-/}
MACHINE=$(sudo dmidecode -s system-product-name)
mkdir -p "results/${YYYYMMDD}"

echo -e "{
    \"system\": \"Doris (Parquet, partitioned)\",
    \"date\": \"${DATE}\",
    \"machine\": \"${MACHINE}\",
    \"cluster_size\": 1,
    \"comment\": \"\",
    \"tags\": [\"C++\", \"column-oriented\", \"MySQL compatible\", \"ClickHouse derivative\"],
    \"load_time\": 0,
    \"data_size\": 14737666736,
    \"result\": [
$(
    r=$(sed -r -e 's/query[0-9]+,/[/; s/$/],/' result.csv)
    echo "${r%?}"
)
    ]
}
" | tee "results/${YYYYMMDD}/${MACHINE}.json"
