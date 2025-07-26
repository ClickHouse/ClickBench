#!/bin/bash

# ⚠️ Derived from spark/run.sh — keep in sync where possible (check README.md for the details).

cat queries.sql | while read query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    ./query.py <<< "${query}"
done
