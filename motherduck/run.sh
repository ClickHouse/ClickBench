#!/bin/bash

cat queries.sql | while read -r query; do
    ./query.py <<< "${query}"
done
