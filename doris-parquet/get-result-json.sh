#!/bin/bash

# set -x
if [[ ! -d results ]]; then mkdir results; fi

echo -e "{
    \"system\": \"Apache Doris (Parquet, partitioned)\",
    \"date\": \"$(date '+%Y-%m-%d')\",
    \"machine\": \"$(sudo dmidecode -s system-product-name), 500gb gp2\",
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
" | tee results/"$(sudo dmidecode -s system-product-name).json"

