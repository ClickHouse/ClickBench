#!/usr/bin/env bash
# Prepare uk_price_paid.native - the UK land registry "price paid" dataset
# (single table, ~28M rows / ~200 MB), following the ClickHouse docs' preprocessing
# (split postcode, Y/N -> is_new, transform type/duration). Types are already
# oldest-compatible after LowCardinality(String) -> String and Enum8 -> String;
# the natural `date` serves the legacy MergeTree engine.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
OUT="${HERE}/data/uk_price_paid.native.zst"
SRC="http://prod1.publicdata.landregistry.gov.uk.s3-website-eu-west-1.amazonaws.com/pp-complete.csv"
command -v "${CLICKHOUSE}" >/dev/null 2>&1 || CLICKHOUSE=clickhouse

echo "uk: building from ${SRC} -> ${OUT}"
"${CLICKHOUSE}" local --max_memory_usage 0 --query "
SELECT
    toUInt32(price_string) AS price,
    toDate(parseDateTimeBestEffortUS(time)) AS date,
    splitByChar(' ', postcode)[1] AS postcode1,
    splitByChar(' ', postcode)[2] AS postcode2,
    transform(a, ['T', 'S', 'D', 'F', 'O'], ['terraced', 'semi-detached', 'detached', 'flat', 'other'], '') AS type,
    b = 'Y' AS is_new,
    transform(c, ['F', 'L', 'U'], ['freehold', 'leasehold', 'unknown'], '') AS duration,
    addr1, addr2, street, locality, town, district, county
FROM url('${SRC}', 'CSV',
    'uuid_string String, price_string String, time String, postcode String, a String, b String, c String, addr1 String, addr2 String, street String, locality String, town String, district String, county String, d String, e String')
SETTINGS max_http_get_redirects=10
FORMAT Native" | zstd -q -6 -T0 -c > "${OUT}"
ls -l "${OUT}"
