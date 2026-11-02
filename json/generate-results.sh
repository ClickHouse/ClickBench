#!/bin/bash -e

# Builds data.generated.js, the data of the JSONBench page (index.html), from
# the result files <system>/results/<machine>_bluesky_<size>m.json.
#
# Entries of the form {"error": "..."} and entries tagged "historical" are
# skipped, as in the main ClickBench (../generate-results.sh).
#
# "Complexity" is computed as in the main ClickBench: the byte size of the
# zstd-compressed scripts and configs of the system's directory, with comments,
# blank lines and redundant whitespace removed; queries, table definitions,
# results and docs are not counted, nor is the shared driver in lib/. Systems
# without the install script (with a manual procedure) have no value.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

complexity() {
    local files
    if [ -z "$(git ls-files -- "$1/install")" ]; then echo null; return; fi
    mapfile -d '' files < <(git ls-files -z -- "$1/" \
        | grep -zvE '(^[^/]+/results/|\.(json|md|sql|txt|lock|pyc|js|json5|logsql)$|\.sql\.|(^|/)\.(git|docker)ignore$)' \
        | sort -z \
        | xargs -0 --no-run-if-empty grep -Il --null '')
    if [ ${#files[@]} = 0 ]; then echo null; return; fi
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g; /^(#([^a-z]|$)|\/\/)/d; /^$/d' "${files[@]}" \
        | zstd -19 -q -c \
        | wc -c
}

declare -A COMPLEXITY

{
    echo "const data = ["
    FIRST=1
    LANG="" find . -mindepth 3 -maxdepth 3 -path './*/results/*.json' | sed 's|^\./||' | sort | while read -r file
    do
        system_dir="${file%%/*}"
        [ -z "${COMPLEXITY[$system_dir]}" ] && COMPLEXITY[$system_dir]=$(complexity "$system_dir")
        if ! entry=$(jq --compact-output --arg src "$file" --argjson complexity "${COMPLEXITY[$system_dir]}" \
            'select(.error == null) | select((.tags // []) | index("historical") | not) | . + {"source": $src, "complexity": $complexity}' \
            "$file"); then
            echo "Error in $file - skipping" >&2
            continue
        fi
        [ -z "$entry" ] && continue
        [ "${FIRST}" = "0" ] && echo -n ','
        printf '%s\n' "$entry"
        FIRST=0
    done
    echo '];'
} > data.generated.js.new

mv data.generated.js.new data.generated.js
