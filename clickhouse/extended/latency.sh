#!/bin/bash

FQDN="$1"
PASSWORD="$2"

TRIES=10

cat queries_latency.sql | while read -r query; do
    echo "$query"
    clickhouse-local --query "SELECT format(\$\$ $query \$\$, c1) FROM file('random_counters.tsv') ORDER BY rand() LIMIT ${TRIES} FORMAT TSV" |
        clickhouse-benchmark --concurrency 10 --iterations "${TRIES}" --delay 0 --secure --host "$FQDN" --password "$PASSWORD" 2>&1 | grep -F '50.000%'
done
