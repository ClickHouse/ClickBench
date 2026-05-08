#!/bin/bash -e

echo "const data = [" > data.generated.js.new
FIRST=1
LANG="" ls -1 */results/*.json | while read -r file
do
    [[ $file =~ ^(hardware|versions|gravitons)/ ]] && continue;

    if entry=$(jq --compact-output ". += {\"source\": \"${file}\"}" "${file}"); then
        [ "${FIRST}" = "0" ] && echo -n ','
        printf '%s\n' "$entry"
        FIRST=0
    else
        echo "Error in $file — skipping" >&2
    fi
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
