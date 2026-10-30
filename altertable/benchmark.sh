#!/bin/bash

set -e

if [ -z "$ALTERTABLE_USERNAME" ] || [ -z "$ALTERTABLE_PASSWORD" ]; then
  echo "ALTERTABLE_USERNAME and ALTERTABLE_PASSWORD must be set"
  exit 1
fi

BASIC_AUTH_TOKEN=$(echo -n "$ALTERTABLE_USERNAME:$ALTERTABLE_PASSWORD" | base64)
ALTERTABLE_API_URL=${ALTERTABLE_API_URL:-"https://api.altertable.ai"}
ALTERTABLE_CATALOG=${ALTERTABLE_CATALOG:-"clickbench"}
ALTERTABLE_SCHEMA=${ALTERTABLE_SCHEMA:-"main"}

DUCKDB_BIN="${DUCKDB:-duckdb}"
if ! command -v "$DUCKDB_BIN" >/dev/null 2>&1; then
  echo "DuckDB CLI not found. Install DuckDB or set DUCKDB to the duckdb binary path." >&2
  exit 1
fi

HITS_RAW="hits_raw.parquet"
HITS_FINAL="hits.parquet"

# Download the ClickBench-compatible file
echo "Downloading data..."
wget --quiet --continue \
  'https://datasets.clickhouse.com/hits_compatible/hits.parquet' \
  -O "$HITS_RAW"

# Rewrite parquet so timestamp columns are real timestamps
if [ ! -f "$HITS_FINAL" ]; then
  echo "Rewriting parquet to real timestamps..."
  tmp="${HITS_FINAL}.tmp.$$"
  "$DUCKDB_BIN" -batch -c "
    COPY (
      SELECT *
      REPLACE (
        epoch_ms(EventTime * 1000) AS EventTime,
        epoch_ms(ClientEventTime * 1000) AS ClientEventTime,
        epoch_ms(LocalEventTime * 1000) AS LocalEventTime,
        DATE '1970-01-01' + INTERVAL (EventDate) DAYS AS EventDate
      )
      FROM read_parquet('${HITS_RAW}', binary_as_string=true)
    ) TO '${tmp}' (FORMAT PARQUET);
  "
  mv "$tmp" "$HITS_FINAL"
fi

# Upload the data only if the hits table does not exist yet
hits_exists=$(curl --silent --fail-with-body --show-error -X POST \
  -H "Content-Type: application/json" \
  -H "Authorization: Basic $BASIC_AUTH_TOKEN" \
  "$ALTERTABLE_API_URL/validate" \
  -d "$(jq -n \
    --arg statement "SELECT 1 FROM hits LIMIT 0" \
    --arg catalog "$ALTERTABLE_CATALOG" \
    --arg schema "$ALTERTABLE_SCHEMA" \
    '{statement: $statement, catalog: $catalog, schema: $schema}')" | jq -r '.valid')

if [ "$hits_exists" = "true" ]; then
  echo "Table $ALTERTABLE_CATALOG.$ALTERTABLE_SCHEMA.hits already exists, skipping upload"
else
  echo "Uploading data..."
  start_time=$(date +%s)
  curl --silent --fail-with-body --show-error --http1.1 -T "$HITS_FINAL" -X POST \
    -H "Content-Type: application/octet-stream" \
    -H "Authorization: Basic $BASIC_AUTH_TOKEN" \
    "$ALTERTABLE_API_URL/upload?format=parquet&catalog=$ALTERTABLE_CATALOG&schema=$ALTERTABLE_SCHEMA&table=hits&mode=overwrite"
  end_time=$(date +%s)
  load_time=$(echo "$end_time - $start_time" | bc)
  echo "Load time: $load_time"
  echo "Data size: $(stat -f %z "$HITS_FINAL")"
fi

# Run the queries
echo "Running queries..."
./run.sh
