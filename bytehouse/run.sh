#!/bin/bash

TRIES=3
cat queries.sql | while read -r query; do
    for i in $(seq 1 $TRIES); do
        ./bytehouse-cli --user "$user" --account "$account" --password "$password" --region ap-southeast-1 --secure --warehouse "$warehouse" --database test --query "${query}"
    done
done
