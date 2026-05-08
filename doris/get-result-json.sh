#!/bin/bash

# set -x
DATE=$(date -u +%Y-%m-%d)
YYYYMMDD=${DATE//-/}
MACHINE=$(sudo dmidecode -s system-product-name)
mkdir -p "results/${YYYYMMDD}"

echo -e "{
    \"system\": \"Apache Doris\",
    \"date\": \"${DATE}\",
    \"machine\": \"${MACHINE}\",
    \"cluster_size\": 1,
    \"comment\": \"\",
    \"tags\": [\"C++\", \"column-oriented\", \"MySQL compatible\", \"ClickHouse derivative\"],
    \"load_time\": $(cat loadtime),
    \"data_size\": $(cat storage_size),
    \"result\": [
$(
    r=$(sed -r -e 's/query[0-9]+,/[/; s/$/],/' result.csv)
    echo "${r%?}"
)
    ]
}
" | tee "results/${YYYYMMDD}/${MACHINE}.json"
