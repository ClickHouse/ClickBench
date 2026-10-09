#!/bin/bash -e

# Results live under <system>/results/YYYYMMDD/<basename>.json.
# For the website we keep only the latest dated copy per (system, basename),
# and we skip entries tagged "historical" — those are kept in the repo
# as archival data but are not displayed on the dashboard.
# Entries of the form {"error": "..."} are also skipped: the latest run for a
# (system, machine) failed, so the system is omitted from the report.

# "Complexity" is the amount of code needed to run the benchmark for a system:
# the byte size of the zstd-compressed concatenation of all the scripts and
# configs in the system's directory (install, load, start, stop, query, the
# Python and Expect scripts they invoke, etc.), with full-line comments, blank
# lines, and redundant whitespace removed. Queries, table definitions,
# results, and docs are not counted, nor is the shared driver in lib/.
# Systems without the install script (with a manual procedure) have no value.
complexity() {
    local files
    if [ -z "$(git ls-files -- "$1/install")" ]; then echo null; return; fi
    mapfile -d '' files < <(git ls-files -z -- "$1/" \
        | grep -zvE '(^[^/]+/results/|\.(json|md|sql|txt|lock|pyc)$|\.sql\.|(^|/)\.(git|docker)ignore$)' \
        | sort -z \
        | xargs -0 --no-run-if-empty grep -Il --null '')
    if [ ${#files[@]} = 0 ]; then echo null; return; fi
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g; /^(#([^a-z]|$)|\/\/)/d; /^$/d' "${files[@]}" \
        | zstd -19 -q -c \
        | wc -c
}

declare -A COMPLEXITY

echo "const data = [" > data.generated.js.new
FIRST=1

# Build "<system>/<basename> <full-path>" lines, then keep the last (latest)
# row per key — sorted ascending by date, since YYYYMMDD sorts lexically.
# Use `find` rather than `ls */results/*/*.json`: to avoid overflowing ARG_MAX
# (clickhouse-cloud alone has tens of thousands of files)
LANG="" find */results -mindepth 2 -maxdepth 2 -name '*.json' \
    | grep -Ev '^(hardware|versions|gravitons)/' \
    | sort \
    | awk -F/ '{ print $1"/"$NF" "$0 }' \
    | awk '{ latest[$1] = $2 } END { for (k in latest) print latest[k] }' \
    | sort \
    | while read -r file
do
    # Derive the date from the YYYYMMDD directory name (3rd path segment) so we
    # can fall back to it when the JSON itself omits .date.
    date_dir=$(echo "$file" | awk -F/ '{print $3}')
    date_iso="${date_dir:0:4}-${date_dir:4:2}-${date_dir:6:2}"
    system_dir="${file%%/*}"
    [ -z "${COMPLEXITY[$system_dir]}" ] && COMPLEXITY[$system_dir]=$(complexity "$system_dir")
    if ! entry=$(jq --compact-output --arg src "$file" --arg date "$date_iso" --argjson complexity "${COMPLEXITY[$system_dir]}" \
        'select(.error == null) | select((.tags // []) | index("historical") | not) | (if (.date // "") == "" then .date = $date else . end) | . + {"source": $src, "complexity": $complexity}' \
        "$file"); then
        echo "Error in $file — skipping" >&2
        continue
    fi
    [ -z "$entry" ] && continue
    [ "${FIRST}" = "0" ] && echo -n ','
    printf '%s\n' "$entry"
    FIRST=0
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
