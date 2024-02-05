#!/bin/bash

cat queries.sql | while read query; do
    ./query.py <<< "${query}"
done
