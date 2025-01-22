#!/bin/bash

# This is needed on Mac OS. Do `brew install coreutils`.
[ -n "$HOMEBREW_PREFIX" ] && PATH="${HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${PATH}"

for f in */result
do
    echo $f
    PROVIDER=$(echo "$f" | grep -o -E '^[a-z]+')
    MACHINE=$(echo "$f" | sed -r -e 's~^[a-z0-9-]+-([0-9]+)-[0-9]+-[0-9]+/.*$~\1~; s/([0-9]+)/\1GB/')
    REPLICAS=$(echo "$f" | sed -r -e 's~^[a-z0-9-]+-[0-9]+-([0-9]+)-[0-9]+/.*$~\1~')

    echo '
{
    "system": "ClickHouse Cloud ('$PROVIDER')",
    "date": "'$(date +%F)'",
    "machine": "'$MACHINE'",
    "cluster_size": "'$REPLICAS'",
    "comment": "",

    "tags": ["C++", "column-oriented", "ClickHouse derivative", "managed", "'$PROVIDER'"],

    "load_time": '$(head -n1 "$f" | tr -d "\n")',
    "data_size": '$(tail -n1 "$f" | tr -d "\n")',

    "result": [
'$(grep -F "[" "$f" | head -c-2)'
]
}
' > "results/${PROVIDER}.${MACHINE}.r${REPLICAS}.json"
done
