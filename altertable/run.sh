#!/bin/bash

set -e

if [ -z "$ALTERTABLE_USERNAME" ] || [ -z "$ALTERTABLE_PASSWORD" ]; then
  echo "ALTERTABLE_USERNAME and ALTERTABLE_PASSWORD must be set"
  exit 1
fi

BASIC_AUTH_TOKEN=$(echo -n "$ALTERTABLE_USERNAME:$ALTERTABLE_PASSWORD" | base64 -w 0)
TRIES=3
QUERY_NUM=1

ALTERTABLE_API_URL=${ALTERTABLE_API_URL:-"https://api.altertable.ai"}
ALTERTABLE_CATALOG=${ALTERTABLE_CATALOG:-"clickbench"}
ALTERTABLE_SCHEMA=${ALTERTABLE_SCHEMA:-"main"}
ALTERTABLE_COMPUTE_SIZE=${ALTERTABLE_COMPUTE_SIZE:-"L"}

function query() {
    local query=$1
    local resp line1 line2 line http_code

    resp=$(curl --silent --show-error --raw -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Basic $BASIC_AUTH_TOKEN" \
      -w "\n%{http_code}" \
      "$ALTERTABLE_API_URL/query" \
      -d "$(jq -n \
        --arg statement "$query" \
        --arg catalog "$ALTERTABLE_CATALOG" \
        --arg schema "$ALTERTABLE_SCHEMA" \
        --arg compute_size "$ALTERTABLE_COMPUTE_SIZE" \
        '{statement: $statement, catalog: $catalog, schema: $schema, compute_size: $compute_size}')") || {
      echo "Query request failed (curl exit $?)" >&2
      printf '%s\n' "$resp" >&2
      return 1
    }

    http_code=$(printf '%s\n' "$resp" | tail -n1)
    resp=$(printf '%s\n' "$resp" | sed '$d')

    if ! [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      echo "Query failed (HTTP ${http_code})" >&2
      printf '%s\n' "$resp" >&2
      return 1
    fi

    line1=$(printf '%s\n' "$resp" | head -n1)
    line2=$(printf '%s\n' "$resp" | head -n2 | tail -n1)

    for line in "$line1" "$line2"; do
      [ -z "$line" ] && continue
      if echo "$line" | jq -e 'type == "object" and has("error") and (.error != null)' >/dev/null 2>&1; then
        echo "SQL error: $(echo "$line" | jq -r '.error')" >&2
        exit 1
      fi
    done

    printf '%s\n' "$resp" | head -n1 | jq -r '.query_id'
}

function get_compute_time() {
  local query_id=$1

  curl --silent --fail-with-body --show-error --raw -X GET \
    -H "Content-Type: application/json" \
    -H "Authorization: Basic $BASIC_AUTH_TOKEN" \
    "$ALTERTABLE_API_URL/query/$query_id" | jq -r '.duration_ms / 1000'
}

while read -r query; do
    sync

    echo -n "["
    for i in $(seq 1 $TRIES); do
        QUERY_ID=$(query "$query")
        COMPUTE_TIME=$(get_compute_time "$QUERY_ID")
        [[ "$?" == "0" ]] && echo -n "${COMPUTE_TIME}" || echo -n "null"
        [[ "$i" != $TRIES ]] && echo -n ", "

        echo "${QUERY_NUM},${i},${COMPUTE_TIME}" >> result.csv
    done
    echo "],"

    QUERY_NUM=$((QUERY_NUM + 1))
done < queries.sql
