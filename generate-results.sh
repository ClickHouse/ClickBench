#!/bin/bash -e

# Results live under <system>/results/YYYYMMDD/<basename>.json.
# For the website we keep only the latest dated copy per (system, basename).

echo "const data = [" > data.generated.js.new
FIRST=1

# Build "<system>/<basename> <full-path>" lines, then keep the last (latest)
# row per key — sorted ascending by date, since YYYYMMDD sorts lexically.
LANG="" ls -1 */results/*/*.json \
    | grep -Ev '^(hardware|versions|gravitons)/' \
    | sort \
    | awk -F/ '{ print $1"/"$NF" "$0 }' \
    | awk '{ latest[$1] = $2 } END { for (k in latest) print latest[k] }' \
    | sort \
    | while read -r file
do
    [ "${FIRST}" = "0" ] && echo -n ','
    jq --compact-output ". += {\"source\": \"${file}\"}" "${file}" || echo "Error in $file" >&2
    FIRST=0
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
