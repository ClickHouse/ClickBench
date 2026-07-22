#!/usr/bin/env bash
# Prepare taxi.native — the NYC taxi "trips" table (classic ClickHouse dataset).
#
# The source CSVs have 51 positional columns, but the 4 taxi queries only touch
# five, so we project just those (a ~10x smaller file than the full width):
#   pickup_date (synthesised Date, also the legacy MergeTree engine's date),
#   cab_type, passenger_count, trip_distance, total_amount.
# Every needed field is read as String (so parsing never fails across the whole
# dump) and cast to the oldest-compatible target type; cab_type (an Enum in
# modern schemas) is downgraded to String.
#
# TAXI_GLOB selects the source files: a single file for a quick slice, or
# trips_*.csv.gz (default) for the full ~1.3B-row dataset.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
OUT="${HERE}/data/taxi.native.zst"
GLOB="${TAXI_GLOB:-trips_*.csv.gz}"
SRC="https://clickhouse-datasets.s3.amazonaws.com/taxi/csv/${GLOB}"

# 51 positional String columns.
STRUCT="$(for i in $(seq 1 51); do printf 'c%d String, ' "$i"; done | sed 's/, $//')"

echo "taxi: building trips from ${GLOB} -> ${OUT}"
"${CLICKHOUSE}" local --max_memory_usage 0 \
    --query "
SELECT
    toDate(parseDateTimeBestEffortOrZero(c3))      AS pickup_date,
    c25                                            AS cab_type,
    toUInt8OrZero(c11)                             AS passenger_count,
    toFloat64OrZero(c12)                           AS trip_distance,
    toFloat32OrZero(c20)                           AS total_amount
FROM s3('${SRC}', 'CSV', '${STRUCT}') ORDER BY pickup_date
FORMAT Native" | zstd -q -6 -T0 -c > "${OUT}"
ls -l "${OUT}"
