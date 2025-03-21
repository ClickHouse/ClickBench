#!/bin/bash

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    ./query.py <<< "${query}"
done
