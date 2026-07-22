#!/usr/bin/env bash
# Emit a CREATE TABLE statement for <table> of <dataset>, tailored to <version>.
#
#   ./create.sh <version> <dataset> <table>
#
# Datasets: hits | ssb | mgbench | tpch | tpcds | coffeeshop | taxi
# Each dataset is loaded into its own database (named after the dataset), so
# tables with the same name across datasets (e.g. TPC-H and TPC-DS both have a
# `customer`) never collide. The statement here is unqualified; the runner
# creates it with `--database <dataset>`.
#
# The same Native data files load into every version, so only the *engine*
# clause changes with the version:
#   * Modern releases use custom-partitioning syntax:
#         ENGINE = MergeTree PARTITION BY toYYYYMM(<date>) ORDER BY (<key>)
#   * The earliest 1.1.x releases (before custom partitioning landed) only
#     understand the legacy positional syntax, which needs a Date column:
#         ENGINE = MergeTree(<date>, (<key>), 8192)
# Every table therefore carries a Date column (a natural one where it exists,
# else a synthesised constant synth_date) usable by the legacy engine.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION="${1:?usage: create.sh <version> <dataset> <table>}"
DATASET="${2:?usage: create.sh <version> <dataset> <table>}"
TABLE="${3:?usage: create.sh <version> <dataset> <table>}"

# Custom-partitioning (new) syntax landed in 1.1.54310; everything from 18.x
# on supports it. Older 1.1.x builds get the legacy positional engine.
new_syntax() {
    local major minor patch
    [ "$VERSION" = "master" ] && return 0   # dev build: modern custom-partitioning syntax
    IFS=. read -r major minor patch _ <<<"$VERSION"
    if [[ "$VERSION" =~ ^[0-9]+$ ]]; then
        # Bare build number (earliest 2016 releases, e.g. 53973..54011): custom
        # partitioning landed at build 54310, and all bare tags predate it.
        [ "$VERSION" -ge 54310 ]
    elif [ "$major" = "1" ] && [ "$minor" = "1" ]; then
        [ "${patch:-0}" -ge 54310 ]
    else
        [ "$major" -ge 18 ]
    fi
}

# The prehistoric monthly reconstructions are labeled by month (YYYY-MM-01) and all
# report version 0.0.<rev>, so they can't be classified by version number. Their engine
# support (probed empirically across the reconstructed images) falls into tiers:
#   2012-04 .. 2012-12  MergeTree is non-functional     -> ENGINE = Log
#   2013-01 .. 2014-03  MergeTree needs a mandatory       -> MergeTree(date, <sample>,
#                       sampling expression                             (key,<sample>), 8192)
#   2014-04 and later   plain positional MergeTree works -> MergeTree(date,(key),8192)
# (2012-04/05 additionally have no scriptable client, so they will load nothing regardless;
# Log is emitted for them for consistency.) Echoes the tier, or "" for non-prehistoric
# versions (handled by new_syntax above).
prehistoric_tier() {
    [[ "$VERSION" =~ ^([0-9]{4})-([0-9]{2})-[0-9]{2}$ ]] || { echo ""; return; }
    local ym="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    if   [ "$ym" -le 201212 ]; then echo log
    elif [ "$ym" -le 201403 ]; then echo legacy_sample
    else                            echo legacy_plain
    fi
}

# `customer` exists in both TPC-H and TPC-DS with different schemas, so it is
# disambiguated by dataset (and its columns file is dataset-qualified below).
if [ "$TABLE" = "customer" ]; then
    DATE_COL=synth_date
    if [ "$DATASET" = "tpcds" ]; then ORDER_KEY="c_customer_sk"; else ORDER_KEY="c_custkey"; fi
else
case "$TABLE" in
    hits)           DATE_COL=EventDate;   ORDER_KEY="CounterID, EventDate, intHash32(UserID), EventTime" ;;
    lineorder_flat) DATE_COL=LO_ORDERDATE; ORDER_KEY="LO_ORDERDATE, LO_ORDERKEY" ;;
    logs1)          DATE_COL=log_date;    ORDER_KEY="machine_group, machine_name, log_time" ;;
    logs2)          DATE_COL=log_date;    ORDER_KEY="log_time" ;;
    logs3)          DATE_COL=log_date;    ORDER_KEY="event_type, log_time" ;;
    trips)          DATE_COL=pickup_date; ORDER_KEY="cab_type, passenger_count" ;;
    ontime)         DATE_COL=FlightDate;  ORDER_KEY="Year, Month, FlightDate, IATA_CODE_Reporting_Airline" ;;
    uk_price_paid)  DATE_COL=date;        ORDER_KEY="postcode1, postcode2, addr1, addr2" ;;
    # TPC-H. Dimension tables have no date, so they carry a synthesised constant
    # synth_date usable by the legacy positional engine; the two fact tables use
    # their natural date (o_orderdate / l_shipdate).
    nation)         DATE_COL=synth_date;  ORDER_KEY="n_nationkey" ;;
    region)         DATE_COL=synth_date;  ORDER_KEY="r_regionkey" ;;
    part)           DATE_COL=synth_date;  ORDER_KEY="p_partkey" ;;
    supplier)       DATE_COL=synth_date;  ORDER_KEY="s_suppkey" ;;
    partsupp)       DATE_COL=synth_date;  ORDER_KEY="ps_partkey, ps_suppkey" ;;
    orders)         DATE_COL=o_orderdate; ORDER_KEY="o_orderkey" ;;
    lineitem)       DATE_COL=l_shipdate;  ORDER_KEY="l_orderkey, l_linenumber" ;;
    # TPC-DS. Only Decimal was downgraded (-> Float64); all 24 tables carry a
    # constant synth_date for the legacy engine, with the spec primary key as
    # the sort key.
    call_center)            DATE_COL=synth_date; ORDER_KEY="cc_call_center_sk" ;;
    catalog_page)           DATE_COL=synth_date; ORDER_KEY="cp_catalog_page_sk" ;;
    catalog_returns)        DATE_COL=synth_date; ORDER_KEY="cr_item_sk, cr_order_number" ;;
    catalog_sales)          DATE_COL=synth_date; ORDER_KEY="cs_item_sk, cs_order_number" ;;
    customer_address)       DATE_COL=synth_date; ORDER_KEY="ca_address_sk" ;;
    customer_demographics)  DATE_COL=synth_date; ORDER_KEY="cd_demo_sk" ;;
    date_dim)               DATE_COL=synth_date; ORDER_KEY="d_date_sk" ;;
    household_demographics) DATE_COL=synth_date; ORDER_KEY="hd_demo_sk" ;;
    income_band)            DATE_COL=synth_date; ORDER_KEY="ib_income_band_sk" ;;
    inventory)              DATE_COL=synth_date; ORDER_KEY="inv_date_sk, inv_item_sk, inv_warehouse_sk" ;;
    item)                   DATE_COL=synth_date; ORDER_KEY="i_item_sk" ;;
    promotion)              DATE_COL=synth_date; ORDER_KEY="p_promo_sk" ;;
    reason)                 DATE_COL=synth_date; ORDER_KEY="r_reason_sk" ;;
    ship_mode)              DATE_COL=synth_date; ORDER_KEY="sm_ship_mode_sk" ;;
    store_returns)          DATE_COL=synth_date; ORDER_KEY="sr_item_sk, sr_ticket_number" ;;
    store_sales)            DATE_COL=synth_date; ORDER_KEY="ss_item_sk, ss_ticket_number" ;;
    store)                  DATE_COL=synth_date; ORDER_KEY="s_store_sk" ;;
    time_dim)               DATE_COL=synth_date; ORDER_KEY="t_time_sk" ;;
    warehouse)              DATE_COL=synth_date; ORDER_KEY="w_warehouse_sk" ;;
    web_page)               DATE_COL=synth_date; ORDER_KEY="wp_web_page_sk" ;;
    web_returns)            DATE_COL=synth_date; ORDER_KEY="wr_item_sk, wr_order_number" ;;
    web_sales)              DATE_COL=synth_date; ORDER_KEY="ws_item_sk, ws_order_number" ;;
    web_site)               DATE_COL=synth_date; ORDER_KEY="web_site_sk" ;;
    # Coffee Shop benchmark. fact_sales has a natural order_date; the two small
    # dimensions carry synth_date.
    fact_sales)     DATE_COL=order_date; ORDER_KEY="order_id" ;;
    dim_locations)  DATE_COL=synth_date; ORDER_KEY="record_id" ;;
    dim_products)   DATE_COL=synth_date; ORDER_KEY="record_id" ;;
    # Join Order Benchmark (IMDB). No date columns anywhere, so all 21 tables
    # carry a constant synth_date; every table's primary key is `id`.
    aka_name|aka_title|cast_info|char_name|comp_cast_type|company_name|company_type|complete_cast|info_type|keyword|kind_type|link_type|movie_companies|movie_info|movie_info_idx|movie_keyword|movie_link|name|person_info|role_type|title)
                    DATE_COL=synth_date; ORDER_KEY="id" ;;
    *) echo "unknown table: $TABLE" >&2; exit 1 ;;
esac
fi

# Columns file, dataset-qualified where a table name is shared across datasets
# (e.g. schema/tpcds_customer.columns), otherwise the plain schema/<table>.columns.
COLUMNS_FILE="${HERE}/schema/${DATASET}_${TABLE}.columns"
[ -f "${COLUMNS_FILE}" ] || COLUMNS_FILE="${HERE}/schema/${TABLE}.columns"
COLUMNS="$(cat "${COLUMNS_FILE}")"

echo "DROP TABLE IF EXISTS ${TABLE};"
TIER="$(prehistoric_tier)"
if [ "${TIER}" = "log" ]; then
    # MergeTree not usable this early: Log has no primary key / no parts (so no data_size
    # metric), but loads and scans fine for the queries.
    cat <<SQL
CREATE TABLE ${TABLE}
(
${COLUMNS}
) ENGINE = Log;
SQL
elif [ "${TIER}" = "legacy_sample" ]; then
    # Early MergeTree required a sampling expression as the 2nd positional argument, and it
    # must appear in the primary key. Use a universal date-based one (the day number hashed),
    # since we never actually SAMPLE -- it only has to be a valid unsigned expression.
    SAMPLE="intHash32(toUInt32(${DATE_COL}))"
    cat <<SQL
CREATE TABLE ${TABLE}
(
${COLUMNS}
) ENGINE = MergeTree(${DATE_COL}, ${SAMPLE}, (${ORDER_KEY}, ${SAMPLE}), 8192);
SQL
elif [ "${TIER}" = "legacy_plain" ] || ! new_syntax; then
    cat <<SQL
CREATE TABLE ${TABLE}
(
${COLUMNS}
) ENGINE = MergeTree(${DATE_COL}, (${ORDER_KEY}), 8192);
SQL
else
    cat <<SQL
CREATE TABLE ${TABLE}
(
${COLUMNS}
) ENGINE = MergeTree PARTITION BY toYYYYMM(${DATE_COL}) ORDER BY (${ORDER_KEY});
SQL
fi
