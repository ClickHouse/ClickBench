#!/bin/bash
# Rayforce ClickBench harness — splayed store (flat per-column files).
# Splayed avoids the parted concat-fallback that degraded high-cardinality
# group-bys ~19x.  .csv.splayed builds the store and returns the table in one
# process (cross-process .db.splayed.get still hits a sym-drift bug).
# Bare queries; timing = top-level `╰─┤` total; min-of-3.
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/rayforce/hits_h.csv
STORE=/home/hetoku/data/work/ClickBench/bench10m/rfsplayed
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl

rm -rf "$STORE"
s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.splayed hit-types "%s" "%s")) null)\n' "$CSV" "$STORE" >> "$s"
for i in $(seq 0 42); do
  q=$(cat "q/$(printf 'q%02d' "$i").rfl")
  for r in 1 2 3; do printf '%s\n' "$q" >> "$s"; done
done

"$RAY" -t 8 -i < "$s" 2>&1 | grep -aoE '^╰─┤ [0-9.]+ ms' | awk '{print $2}' > rf_times.txt
rm -f "$s"

mapfile -t T < rf_times.txt
echo "rayforce: ${#T[@]} timings (expect 130: schema+load+43x3)"
: > rf_min.txt
for i in $(seq 0 42); do
  b=$((2 + i*3))
  min=$(printf '%s\n%s\n%s\n' "${T[$b]:-NA}" "${T[$((b+1))]:-NA}" "${T[$((b+2))]:-NA}" | sort -g | head -1)
  printf 'q%02d %s\n' "$i" "$min" >> rf_min.txt
done
cat rf_min.txt
