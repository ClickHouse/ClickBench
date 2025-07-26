#!/bin/bash

# ⚠️ Used as a base for spark-*/run.sh — keep in sync where possible (check README-accelerators.md for the details).

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    ./query.py <<< "${query}"
done
