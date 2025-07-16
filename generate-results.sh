#!/bin/bash -e


echo "const data = [" > data.generated.js.new
FIRST=1
LANG="" ls -1 */results/*.json | while read -r file
do
    [[ $file =~ ^(hardware|versions|gravitons)/ ]] && continue;

    [ "${FIRST}" = "0" ] && echo -n ','
    jq --compact-output ". += {\"source\": \"${file}\"}" "${file}" || echo "Error in $file" >&2
    FIRST=0
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
