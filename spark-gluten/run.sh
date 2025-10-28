#!/bin/bash

# Note: Keep in sync with spark-*/run.sh (see README-accelerators.md for details)

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    ./query.py <<< "${query}"
done
