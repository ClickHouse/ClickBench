#!/bin/bash
set -euo pipefail

RAY_BIN=${RAY_BIN:-../../rayforce/rayforce}
RAY_THREADS=${RAY_THREADS:-$(nproc)}
RAY_PARTED_DIR=${RAY_PARTED_DIR:-/skull/tmp/rayforce_tests/current}
RAY_PART_ROWS=${RAY_PART_ROWS:-1000000}
RAY_REBUILD_PARTED=${RAY_REBUILD_PARTED:-0}
if [ ! -x "$RAY_BIN" ]; then
  RAY_BIN=${RAY_BIN:-./.rf-src/rayforce}
fi
if [ ! -x "$RAY_BIN" ]; then
  echo "missing executable" >&2
  exit 1
fi

script=$(mktemp)
trap 'rm -f "$script"' EXIT

cat schema.rfl > "$script"
if [ "$RAY_REBUILD_PARTED" = "1" ] || [ ! -d "$RAY_PARTED_DIR" ]; then
  rm -rf "$RAY_PARTED_DIR"
  printf '\n(do (set hits (.csv.parted hit-names hit-types "hits.csv" %s "%s/" '"'"'hits)) null)\n' "$RAY_PART_ROWS" "$RAY_PARTED_DIR" >> "$script"
else
  printf '\n(do (set hits (.db.parted.get "%s" '"'"'hits)) null)\n' "$RAY_PARTED_DIR" >> "$script"
fi
while IFS= read -r -d '' query; do
  [ -z "$query" ] && continue
  printf '(do %s null)\n' "$query" >> "$script"
  printf '(do %s null)\n' "$query" >> "$script"
  printf '(do %s null)\n' "$query" >> "$script"
done < <(awk '
  /^[[:space:]]*$/ { next }
  {
    query = query $0 "\n"
    parens = $0
    gsub(/[^()]/, "", parens)
    for (i = 1; i <= length(parens); i++) {
      c = substr(parens, i, 1)
      if (c == "(") depth++
      else if (c == ")") depth--
    }
    if (depth == 0 && query != "") {
      printf "%s%c", query, 0
      query = ""
    }
  }
  END {
    if (query != "") printf "%s%c", query, 0
  }
' queries.rfl)

"$RAY_BIN" -t "$RAY_THREADS" -i < "$script" 2>&1 | tee log.txt
if grep -q '^error:' log.txt; then
  echo "query execution failed" >&2
  exit 1
fi

mapfile -t times < <(awk '/^╰/ && /ms$/ { printf "%.6f\n", $2 / 1000.0 }' log.txt)
if [ "${#times[@]}" -ne 131 ]; then
  echo "timing count mismatch: ${#times[@]}" >&2
  exit 1
fi

echo "Load time: ${times[1]}"
echo "Data size: $(du -sb "$RAY_PARTED_DIR" | awk '{print $1}')"

for ((i = 2; i < ${#times[@]}; i += 3)); do
  printf '[%s,%s,%s],\n' "${times[i]}" "${times[i+1]}" "${times[i+2]}"
done
