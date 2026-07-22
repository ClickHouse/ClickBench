#!/usr/bin/env bash
# Prepare the Coffee Shop benchmark dataset as oldest-ClickHouse-compatible
# Native files, from the published Iceberg tables in the public bucket
# (s3://clickhouse-datasets/coffeeshop/). Table definitions match the
# coffeeshop-benchmark repo (clickhouse-cloud/tables.sql).
#
# COFFEESHOP_SCALE selects the fact table (default 500m, the smallest of
# 500m/1b/5b). All types are already oldest-compatible (String/Int32/Float64/
# Date); NULLs are replaced with defaults (COALESCE) so the non-Nullable columns
# load, and the two small dimensions carry a constant synth_date for the legacy
# MergeTree engine (fact_sales uses its natural order_date). The unused
# high-cardinality order_line_id column is dropped (no query references it),
# which roughly halves the fact table's size.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
SCALE="${COFFEESHOP_SCALE:-500m}"
BUCKET="https://clickhouse-datasets.s3.amazonaws.com/coffeeshop"
command -v "${CLICKHOUSE}" >/dev/null 2>&1 || CLICKHOUSE=clickhouse

# Read an Iceberg table from the public bucket and re-emit it as oldest-
# compatible Native, columns/order matching create/schema/<table>.columns.
emit() {
    local out="$1" src="$2" sel="$3"
    echo "coffeeshop: building ${out} from ${src}"
    "${CLICKHOUSE}" local --max_memory_usage 0 \
        --query "SELECT ${sel} FROM icebergS3('${src}', NOSIGN) FORMAT Native" \
        | zstd -q -6 -T0 -c > "${HERE}/data/${out}"
    echo "  ${out}: $(du -h "${HERE}/data/${out}" | cut -f1)"
}

D="CAST('2000-01-01' AS Date) AS synth_date"

emit coffeeshop_dim_locations.native.zst "${BUCKET}/dim_locations/" \
"${D}, CAST(ifNull(record_id,'') AS String) AS record_id, CAST(ifNull(location_id,'') AS String) AS location_id, CAST(ifNull(city,'') AS String) AS city, CAST(ifNull(state,'') AS String) AS state, CAST(ifNull(country,'') AS String) AS country, CAST(ifNull(region,'') AS String) AS region"

emit coffeeshop_dim_products.native.zst "${BUCKET}/dim_products/" \
"${D}, CAST(ifNull(record_id,'') AS String) AS record_id, CAST(ifNull(product_id,'') AS String) AS product_id, CAST(ifNull(name,'') AS String) AS name, CAST(ifNull(category,'') AS String) AS category, CAST(ifNull(subcategory,'') AS String) AS subcategory, CAST(ifNull(standard_cost,0) AS Float64) AS standard_cost, CAST(ifNull(standard_price,0) AS Float64) AS standard_price, CAST(ifNull(from_date, toDate(0)) AS Date) AS from_date, CAST(ifNull(to_date, toDate(0)) AS Date) AS to_date"

emit coffeeshop_fact_sales.native.zst "${BUCKET}/fact_sales_${SCALE}/" \
"CAST(ifNull(order_id,'') AS String) AS order_id, CAST(ifNull(order_date, toDate(0)) AS Date) AS order_date, CAST(ifNull(time_of_day,'') AS String) AS time_of_day, CAST(ifNull(season,'') AS String) AS season, CAST(ifNull(month,0) AS Int32) AS month, CAST(ifNull(location_id,'') AS String) AS location_id, CAST(ifNull(region,'') AS String) AS region, CAST(ifNull(product_name,'') AS String) AS product_name, CAST(ifNull(quantity,0) AS Int32) AS quantity, CAST(ifNull(sales_amount,0) AS Float64) AS sales_amount, CAST(ifNull(discount_percentage,0) AS Int32) AS discount_percentage, CAST(ifNull(product_id,'') AS String) AS product_id"

echo "coffeeshop: done"
