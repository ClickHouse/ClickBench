#!/usr/bin/env bash
# Prepare ssb.native — the Star Schema Benchmark denormalised lineorder_flat
# table built from the published .tbl files (scale factor SSB_SCALE, default 100).
#
# The source .tbl files are comma-separated with quoted strings and ISO dates.
# We join lineorder against the three dimension tables and add the F_YEAR
# column the query set expects, emitting only oldest-compatible types.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
OUT="${HERE}/data/ssb.native.zst"
SCALE="${SSB_SCALE:-100}"
BASE="https://clickhouse-public-datasets.s3.amazonaws.com/ssb/original/${SCALE}"

LO_S="LO_ORDERKEY UInt32, LO_LINENUMBER UInt8, LO_CUSTKEY UInt32, LO_PARTKEY UInt32, LO_SUPPKEY UInt32, LO_ORDERDATE Date, LO_ORDERPRIORITY String, LO_SHIPPRIORITY UInt8, LO_QUANTITY UInt8, LO_EXTENDEDPRICE UInt32, LO_ORDTOTALPRICE UInt32, LO_DISCOUNT UInt8, LO_REVENUE UInt32, LO_SUPPLYCOST UInt32, LO_TAX UInt8, LO_COMMITDATE Date, LO_SHIPMODE String"
C_S="C_CUSTKEY UInt32, C_NAME String, C_ADDRESS String, C_CITY String, C_NATION String, C_REGION String, C_PHONE String, C_MKTSEGMENT String"
S_S="S_SUPPKEY UInt32, S_NAME String, S_ADDRESS String, S_CITY String, S_NATION String, S_REGION String, S_PHONE String"
P_S="P_PARTKEY UInt32, P_NAME String, P_MFGR String, P_CATEGORY String, P_BRAND String, P_COLOR String, P_TYPE String, P_SIZE UInt8, P_CONTAINER String"

echo "ssb: building lineorder_flat at scale ${SCALE} -> ${OUT}"
"${CLICKHOUSE}" local --max_memory_usage 0 \
    --input_format_csv_allow_variable_number_of_columns 1 \
    --query "
SELECT
    lo.LO_ORDERKEY, lo.LO_LINENUMBER, lo.LO_CUSTKEY, lo.LO_PARTKEY, lo.LO_SUPPKEY,
    lo.LO_ORDERDATE, lo.LO_ORDERPRIORITY, lo.LO_SHIPPRIORITY, lo.LO_QUANTITY,
    lo.LO_EXTENDEDPRICE, lo.LO_ORDTOTALPRICE, lo.LO_DISCOUNT, lo.LO_REVENUE,
    lo.LO_SUPPLYCOST, lo.LO_TAX, lo.LO_COMMITDATE, lo.LO_SHIPMODE,
    c.C_NAME, c.C_ADDRESS, c.C_CITY, c.C_NATION, c.C_REGION, c.C_PHONE, c.C_MKTSEGMENT,
    s.S_NAME, s.S_ADDRESS, s.S_CITY, s.S_NATION, s.S_REGION, s.S_PHONE,
    p.P_NAME, p.P_MFGR, p.P_CATEGORY, p.P_BRAND, p.P_COLOR, p.P_TYPE, p.P_SIZE, p.P_CONTAINER,
    toYear(lo.LO_ORDERDATE) AS F_YEAR
FROM url('${BASE}/lineorder.tbl.xz', 'CSV', '${LO_S}') AS lo
INNER JOIN url('${BASE}/customer.tbl.xz', 'CSV', '${C_S}') AS c ON lo.LO_CUSTKEY = c.C_CUSTKEY
INNER JOIN url('${BASE}/supplier.tbl.xz', 'CSV', '${S_S}') AS s ON lo.LO_SUPPKEY = s.S_SUPPKEY
INNER JOIN url('${BASE}/part.tbl.xz',     'CSV', '${P_S}') AS p ON lo.LO_PARTKEY = p.P_PARTKEY
FORMAT Native" | zstd -q -6 -T0 -c > "${OUT}"
ls -l "${OUT}"
