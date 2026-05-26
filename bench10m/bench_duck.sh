#!/bin/bash
# DuckDB ClickBench harness — runs all 43 queries x3 against hits.db (10M rows).
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
DB=hits.db
DUCK=/tmp/duckdb_bin/duckdb
QUERIES=/home/hetoku/data/work/ClickBench/duckdb/queries.sql

: > duck_min.txt
i=0
while IFS= read -r q; do
  [ -z "$q" ] && continue
  params=(-c ".timer on")
  for r in 1 2 3; do params+=(-c "$q"); done
  out=$("$DUCK" "$DB" "${params[@]}" 2>&1)
  # Run Time (s): real 0.123 ...  -> seconds; take min of 3, convert to ms
  min=$(echo "$out" | grep -oE 'real [0-9.]+' | awk '{print $2*1000}' | sort -g | head -1)
  printf 'q%02d %s\n' "$i" "${min:-NA}" >> duck_min.txt
  i=$((i+1))
done < "$QUERIES"
cat duck_min.txt
