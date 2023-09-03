#!/bin/bash

for f in */result
do
    PROVIDER=$(echo "$f" | grep -oP '^\w+')
    MACHINE=$(echo "$f" | sed -r -e 's!^[a-z0-9-]+-([0-9]+)-[0-9]+/.+$!\1!; s/^0/dev/; s/([0-9]+)/\1GB/')

    echo '
{
    "system": "ClickHouse Cloud ('$PROVIDER')",
    "date": "'$(date +%F)'",
    "machine": "'$MACHINE'",
    "cluster_size": "serverless",
    "comment": "",

    "tags": ["C++", "column-oriented", "ClickHouse derivative", "managed", "'$PROVIDER'"],

    "load_time": '$(head -n1 "$f" | tr -d "\n")',
    "data_size": '$(tail -n1 "$f" | tr -d "\n")',

    "result": [
'$(grep -F "[" "$f" | head -c-2)'
]
}
' > "results/${PROVIDER}.${MACHINE}.json"
done
