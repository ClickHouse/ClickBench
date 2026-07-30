#!/bin/bash
set -euo pipefail

: "${TINYBIRD_TOKEN:?Set TINYBIRD_TOKEN}"
: "${TINYBIRD_HOST:?Set TINYBIRD_HOST to your workspace API host}"
BASE_URL="${TINYBIRD_HOST%/}/v0/pipes/"
AUTH_HEADER="Authorization: Bearer ${TINYBIRD_TOKEN}"

results="["

for i in {1..43}; do
    times=()
    for j in {1..3}; do
        response=$(curl -fsS --compressed -H "$AUTH_HEADER" "${BASE_URL}Q${i}.json")
        elapsed=$(jq -er '.statistics.elapsed | numbers' <<< "$response")
        times+=("$elapsed")
    done
    results+=$(printf "[%s,%s,%s]," "${times[0]}" "${times[1]}" "${times[2]}")
done

results=${results%,}
results+="]"

echo "$results"
