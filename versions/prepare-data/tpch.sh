#!/usr/bin/env bash
# Prepare the TPC-H dataset as oldest-ClickHouse-compatible Native files.
#
# TPC-H is produced by the standard `dbgen` data generator at scale TPCH_SCALE
# (default 40, which yields ~10 GB of compressed Native across the 8 tables);
# GEN points at a generator that understands `INSTALL tpch; CALL dbgen(sf=N)`
# SQL. Each table is re-emitted with only types the earliest ClickHouse
# understands:
#   Decimal(12,2) -> Float64          (old ClickHouse has no Decimal)
#   CHAR(N)       -> FixedString(N)
#   the rest (UInt32 / Int32 / Date / String) map unchanged.
# The six dimension tables have no date column, so a constant synth_date is
# prepended for the legacy positional MergeTree engine (see create/create.sh).
# Column order and names match create/schema/<table>.columns exactly.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
GEN="${GEN:-generator}"
SCALE="${TPCH_SCALE:-40}"
WORK="${HERE}/data/tpch-work"
mkdir -p "${WORK}"

command -v "${CLICKHOUSE}" >/dev/null 2>&1 || CLICKHOUSE=clickhouse
[ -x "${GEN}" ] || command -v "${GEN}" >/dev/null 2>&1 || {
    echo "generator '${GEN}' not found; set GEN to a data generator" >&2; exit 1; }

echo "tpch: generating scale factor ${SCALE}"
rm -f "${WORK}/tpch.db"
"${GEN}" "${WORK}/tpch.db" <<SQL
INSTALL tpch; LOAD tpch;
CALL dbgen(sf=${SCALE});
SQL
for t in nation region part supplier partsupp customer orders lineitem; do
    "${GEN}" "${WORK}/tpch.db" \
        "COPY (SELECT * FROM ${t}) TO '${WORK}/${t}.parquet' (FORMAT parquet);"
done

# Re-emit each parquet table as oldest-compatible Native, columns in the order
# of create/schema/<table>.columns.
conv() {
    local t="$1" sel="$2"
    "${CLICKHOUSE}" local --max_memory_usage 0 \
        --query "SELECT ${sel} FROM file('${WORK}/${t}.parquet','Parquet') FORMAT Native" \
        | zstd -q -6 -T0 -c > "${HERE}/data/tpch_${t}.native.zst"
    echo "  tpch_${t}.native.zst: $(du -h "${HERE}/data/tpch_${t}.native.zst" | cut -f1)"
}

D="CAST('2000-01-01' AS Date) AS synth_date"
conv nation "${D}, CAST(n_nationkey AS UInt32) AS n_nationkey, CAST(n_name AS FixedString(25)) AS n_name, CAST(n_regionkey AS UInt32) AS n_regionkey, CAST(n_comment AS String) AS n_comment"
conv region "${D}, CAST(r_regionkey AS UInt32) AS r_regionkey, CAST(r_name AS FixedString(25)) AS r_name, CAST(r_comment AS String) AS r_comment"
conv part "${D}, CAST(p_partkey AS UInt32) AS p_partkey, CAST(p_name AS String) AS p_name, CAST(p_mfgr AS FixedString(25)) AS p_mfgr, CAST(p_brand AS FixedString(10)) AS p_brand, CAST(p_type AS String) AS p_type, CAST(p_size AS Int32) AS p_size, CAST(p_container AS FixedString(10)) AS p_container, CAST(p_retailprice AS Float64) AS p_retailprice, CAST(p_comment AS String) AS p_comment"
conv supplier "${D}, CAST(s_suppkey AS UInt32) AS s_suppkey, CAST(s_name AS FixedString(25)) AS s_name, CAST(s_address AS String) AS s_address, CAST(s_nationkey AS UInt32) AS s_nationkey, CAST(s_phone AS FixedString(15)) AS s_phone, CAST(s_acctbal AS Float64) AS s_acctbal, CAST(s_comment AS String) AS s_comment"
conv partsupp "${D}, CAST(ps_partkey AS UInt32) AS ps_partkey, CAST(ps_suppkey AS UInt32) AS ps_suppkey, CAST(ps_availqty AS Int32) AS ps_availqty, CAST(ps_supplycost AS Float64) AS ps_supplycost, CAST(ps_comment AS String) AS ps_comment"
conv customer "${D}, CAST(c_custkey AS UInt32) AS c_custkey, CAST(c_name AS String) AS c_name, CAST(c_address AS String) AS c_address, CAST(c_nationkey AS UInt32) AS c_nationkey, CAST(c_phone AS FixedString(15)) AS c_phone, CAST(c_acctbal AS Float64) AS c_acctbal, CAST(c_mktsegment AS FixedString(10)) AS c_mktsegment, CAST(c_comment AS String) AS c_comment"
conv orders "CAST(o_orderkey AS UInt32) AS o_orderkey, CAST(o_custkey AS UInt32) AS o_custkey, CAST(o_orderstatus AS FixedString(1)) AS o_orderstatus, CAST(o_totalprice AS Float64) AS o_totalprice, CAST(o_orderdate AS Date) AS o_orderdate, CAST(o_orderpriority AS FixedString(15)) AS o_orderpriority, CAST(o_clerk AS FixedString(15)) AS o_clerk, CAST(o_shippriority AS Int32) AS o_shippriority, CAST(o_comment AS String) AS o_comment"
conv lineitem "CAST(l_orderkey AS UInt32) AS l_orderkey, CAST(l_partkey AS UInt32) AS l_partkey, CAST(l_suppkey AS UInt32) AS l_suppkey, CAST(l_linenumber AS Int32) AS l_linenumber, CAST(l_quantity AS Float64) AS l_quantity, CAST(l_extendedprice AS Float64) AS l_extendedprice, CAST(l_discount AS Float64) AS l_discount, CAST(l_tax AS Float64) AS l_tax, CAST(l_returnflag AS FixedString(1)) AS l_returnflag, CAST(l_linestatus AS FixedString(1)) AS l_linestatus, CAST(l_shipdate AS Date) AS l_shipdate, CAST(l_commitdate AS Date) AS l_commitdate, CAST(l_receiptdate AS Date) AS l_receiptdate, CAST(l_shipinstruct AS FixedString(25)) AS l_shipinstruct, CAST(l_shipmode AS FixedString(10)) AS l_shipmode, CAST(l_comment AS String) AS l_comment"

rm -rf "${WORK}"
echo "tpch: done"
