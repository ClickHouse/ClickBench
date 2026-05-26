#!/bin/bash
# Rayforce ClickBench harness — in-memory (.csv.read), honest min-of-3.
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/data/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/rayforce/hits_h.csv
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl

s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.read hit-types "%s")) null)\n' "$CSV" >> "$s"
for i in $(seq 0 42); do
  q=$(cat "q/$(printf 'q%02d' "$i").rfl")
  for r in 1 2 3; do printf '%s\n' "$q" >> "$s"; done
done

"$RAY" -t 8 -i < "$s" 2>&1 | grep -aoE '^╰─┤ [0-9.]+ ms' | awk '{print $2}' > rf_times.txt
rm -f "$s"

mapfile -t T < rf_times.txt
echo "rayforce: ${#T[@]} timings (expect 131: schema+load+43x3)"
: > rf_min.txt
for i in $(seq 0 42); do
  b=$((2 + i*3))
  min=$(printf '%s\n%s\n%s\n' "${T[$b]:-NA}" "${T[$((b+1))]:-NA}" "${T[$((b+2))]:-NA}" | sort -g | head -1)
  printf 'q%02d %s\n' "$i" "$min" >> rf_min.txt
done
cat rf_min.txt
