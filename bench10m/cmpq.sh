#!/bin/bash
# cmpq.sh qNN [qNN ...] — show rayforce vs duckdb 100K output for given queries.
cd /home/hetoku/data/work/ClickBench/bench10m
for q in "$@"; do
  echo "############### $q ###############"
  echo "--- RAYFORCE ---"
  awk "/=== $q ===/{f=1;next} /=== q[0-9]/{f=0} f" rf100k_out.txt \
    | grep -vE '✶|╭ top|╭ optimize|╭ SELECT|╭ FILTER|╭ GROUP|╭ SORT|╭ HEAD|╰─┤|^│ │|^│ ✶'
  echo "--- DUCKDB ---"
  awk "/=== $q ===/{f=1;next} /=== q[0-9]/{f=0} f" duck100k_out.txt
  echo
done
