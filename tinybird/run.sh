#!/bin/bash
set -euo pipefail

BASE_URL="https://api.tinybird.co/v0/pipes/"
: "${TINYBIRD_TOKEN:?Set TINYBIRD_TOKEN}"
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
