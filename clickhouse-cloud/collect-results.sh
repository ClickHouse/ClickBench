#!/bin/bash

# This is needed on Mac OS. Do `brew install coreutils`.
[ -n "$HOMEBREW_PREFIX" ] && PATH="${HOMEBREW_PREFIX}/opt/coreutils/libexec/gnubin:${PATH}"

DATE=$(date -u +%F)
YYYYMMDD=${DATE//-/}
mkdir -p "results/$YYYYMMDD"

for f in */result
do
    echo $f
    REGEXP='^csp-([a-z0-9-]+)-region-([a-z0-9-]+)-replicas-([a-z0-9-]+)-memory-([a-z0-9-]+)-parallel-([a-z0-9-]+)-pid-([a-z0-9-]+)/result$'
    PROVIDER=$(echo "$f" | sed -r -e 's!'$REGEXP'!\1!')
    REPLICAS=$(echo "$f" | sed -r -e 's!'$REGEXP'!\3!')
    MEMORY=$(echo "$f" | sed -r -e 's!'$REGEXP'!\4!')

    LOAD_TIME=$(head -n1 "$f" | tr -d "\n")
    DATA_SIZE=$(tail -n1 "$f" | tr -d "\n")
    RESULT_BODY=$(grep -F "[" "$f" | head -c-2)

    # Skip when the raw result file is incomplete — load time / data size must
    # be plain numbers and the result body must be non-empty. Otherwise the
    # generated JSON would be malformed and pollute the repository.
    if ! [[ "$LOAD_TIME" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       || ! [[ "$DATA_SIZE" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
       || [ -z "$RESULT_BODY" ]; then
        echo "Skipping $f: malformed raw result (load_time='$LOAD_TIME', data_size='$DATA_SIZE', empty_body=$([ -z "$RESULT_BODY" ] && echo yes || echo no))" >&2
        continue
    fi

    OUT="results/$YYYYMMDD/${PROVIDER}.${REPLICAS}.${MEMORY}.json"
    echo '
{
    "system": "ClickHouse ☁️ ('$PROVIDER')",
    "date": "'$DATE'",
    "machine": "ClickHouse ☁️: '$MEMORY'GiB",
    "cluster_size": '$REPLICAS',
    "proprietary": "yes",
    "hardware": "cpu",
    "tuned": "no",
    "comment": "",

    "tags": ["C++", "column-oriented", "ClickHouse derivative", "managed", "'$PROVIDER'", "lukewarm-cold-run"],

    "load_time": '$LOAD_TIME',
    "data_size": '$DATA_SIZE',

    "result": [
'"$RESULT_BODY"'
]
}
' > "$OUT"

    # Defence in depth: drop anything that didn't end up as parseable JSON.
    if ! jq empty "$OUT" 2>/dev/null; then
        echo "Discarding $OUT: produced JSON failed to parse" >&2
        rm -f "$OUT"
    fi
done
