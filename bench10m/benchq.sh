#!/bin/bash
# benchq.sh NN [NN ...] — load hits once, run each listed query REPS times (min reported).
# Timing lines: line 1 = schema eval, line 2 = load eval, then REPS per query in order.
set -uo pipefail
cd /home/hetoku/data/work/ClickBench/bench10m
RAY=/home/hetoku/data/work/rayforce/rayforce
CSV=/home/hetoku/data/work/ClickBench/rayforce/hits_h.csv
SCHEMA=/home/hetoku/data/work/ClickBench/rayforce/schema.rfl
REPS=${REPS:-7}

s=$(mktemp)
cat "$SCHEMA" > "$s"
printf '(do (set hits (.csv.read hit-types "%s")) null)\n' "$CSV" >> "$s"
for i in "$@"; do
  q=$(cat "q/$(printf 'q%02d' "$((10#$i))").rfl")
  for r in $(seq 1 "$REPS"); do printf '%s\n' "$q" >> "$s"; done
done

mapfile -t T < <("$RAY" -t 8 -i < "$s" 2>&1 | grep -aoE '^╰─┤ [0-9.]+ ms' | awk '{print $2}')
rm -f "$s"
idx=2
for i in "$@"; do
  min=1e18
  for r in $(seq 1 "$REPS"); do
    v=${T[$idx]:-NA}; idx=$((idx+1))
    [ "$v" = NA ] && continue
    awk -v a="$v" -v b="$min" 'BEGIN{exit !(a+0<b+0)}' && min=$v
  done
  printf 'q%02d  min %s ms\n' "$((10#$i))" "$min"
done
