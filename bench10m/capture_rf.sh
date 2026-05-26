#!/bin/bash
# In-memory load, run all 43 queries bare (prints result), capture full output.
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/data/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/rayforce/hits_h.csv
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl

s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.read hit-types "%s")) null)\n' "$CSV" >> "$s"
for i in $(seq 0 42); do
  printf '"=== q%02d ==="\n' "$i" >> "$s"
  cat "q/$(printf 'q%02d' "$i").rfl" >> "$s"
  printf '\n' >> "$s"
done

"$RAY" -t 8 -i < "$s" > rf_out.txt 2>&1
rm -f "$s"
echo "captured $(grep -c '=== q' rf_out.txt) markers"
