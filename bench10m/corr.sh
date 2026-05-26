#!/bin/bash
# Fast correctness harness — 100K rows, in-process splayed build, all 43 queries.
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/data/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/bench10m/hits_100k.csv
STORE=/home/hetoku/data/work/ClickBench/bench10m/rfsplayed100k
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl

rm -rf "$STORE"
s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.splayed hit-types "%s" "%s")) null)\n' "$CSV" "$STORE" >> "$s"
for i in $(seq 0 42); do
  printf '"=== q%02d ==="\n' "$i" >> "$s"
  cat "q/$(printf 'q%02d' "$i").rfl" >> "$s"
  printf '\n' >> "$s"
done
"$RAY" -t 8 -i < "$s" > rf100k_out.txt 2>&1
rm -f "$s"
echo "rf 100k: $(grep -c '=== q' rf100k_out.txt) markers"
