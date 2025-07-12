#!/bin/bash

# This is needed on Mac OS. Do `brew install coreutils`.
[ -n "$HOMEBREW_PREFIX" ] && PATH="${HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${PATH}"

for f in */result
do
    echo $f
    REGEXP='^csp-([a-z0-9-]+)-region-([a-z0-9-]+)-replicas-([a-z0-9-]+)-memory-([a-z0-9-]+)-parallel-([a-z0-9-]+)-pid-([a-z0-9-]+)/result$'
    PROVIDER=$(echo "$f" | sed -r -e 's!'$REGEXP'!\1!')
    REPLICAS=$(echo "$f" | sed -r -e 's!'$REGEXP'!\3!')
    MEMORY=$(echo "$f" | sed -r -e 's!'$REGEXP'!\4!')

    echo '
{
    "system": "ClickHouse ☁️ ('$PROVIDER')",
    "date": "'$(date +%F)'",
    "machine": "'$MEMORY'GiB",
    "cluster_size": '$REPLICAS',
    "proprietary": "yes",
    "tuned": "no",
    "comment": "",

    "tags": ["C++", "column-oriented", "ClickHouse derivative", "managed", "'$PROVIDER'"],

    "load_time": '$(head -n1 "$f" | tr -d "\n")',
    "data_size": '$(tail -n1 "$f" | tr -d "\n")',

    "result": [
'$(grep -F "[" "$f" | head -c-2)'
]
}
' > "results/${PROVIDER}.${REPLICAS}.${MEMORY}.json"
done
