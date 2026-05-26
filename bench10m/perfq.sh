#!/bin/bash
# perfq.sh NN [REPS] — perf-record one query (skips the ~30s load via -D delay).
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/data/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/rayforce/hits_h.csv
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl
QN=$(printf '%02d' "$((10#$1))")
REPS=${2:-150}

s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.read hit-types "%s")) null)\n' "$CSV" >> "$s"
for r in $(seq 1 "$REPS"); do cat "q/q$QN.rfl" >> "$s"; printf '\n' >> "$s"; done

perf record -D 33000 -g --call-graph dwarf -F 999 -o /tmp/q$QN.perf -- \
  "$RAY" -t 8 -i < "$s" > /dev/null 2>&1
rm -f "$s"
echo "recorded /tmp/q$QN.perf"
perf report -i /tmp/q$QN.perf --stdio --no-children 2>/dev/null | \
  grep -E '^\s+[0-9]+\.[0-9]+%' | head -35
