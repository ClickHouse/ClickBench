#!/bin/bash -e

# Results live under <system>/results/YYYYMMDD/<basename>.json.
# For the website we use only the latest date subdirectory of each
# system's results/, and include every file in that subdirectory.
# Older subdirectories are kept on disk as history but not displayed.
# Entries tagged "historical" are also filtered out.

echo "const data = [" > data.generated.js.new
FIRST=1

for dir in */; do
    dir="${dir%/}"
    case "$dir" in
        hardware|versions|gravitons) continue;;
    esac
    [ -d "$dir/results" ] || continue
    latest=$(LANG=C ls -1 "$dir/results" 2>/dev/null | sort | tail -1)
    [ -n "$latest" ] || continue
    [ -d "$dir/results/$latest" ] || continue

    for file in "$dir/results/$latest"/*.json; do
        [ -f "$file" ] || continue
        if ! entry=$(jq --compact-output --arg src "$file" \
            'select((.tags // []) | index("historical") | not) | . + {"source": $src}' \
            "$file"); then
            echo "Error in $file — skipping" >&2
            continue
        fi
        [ -z "$entry" ] && continue
        [ "${FIRST}" = "0" ] && echo -n ','
        printf '%s\n' "$entry"
        FIRST=0
    done
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
