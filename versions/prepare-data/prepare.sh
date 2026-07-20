#!/usr/bin/env bash
# Prepare all Native data files used by the Versions Benchmark.
#
# Produces, under prepare-data/data/ (zstd-compressed Native, level 6):
#   hits.native.zst  ssb.native.zst  mgbench{1,2,3}.native.zst
#   tpch_{nation,region,part,supplier,partsupp,customer,orders,lineitem}.native.zst  taxi.native.zst
#
# These files use only the oldest-compatible ClickHouse types and load into
# every version (including 1.1.x): the runner streams `zstd -dc file | INSERT`,
# so the legacy clickhouse-client only ever sees plain Native.
#
# Scale is controlled by env vars (defaults reproduce the original benchmark):
#   HITS_PARTS=255            # 0..255 -> full 100M rows
#   SSB_SCALE=100             # lineorder_flat ~600M rows
#   TPCH_SCALE=40             # ~10 GB compressed
#   TAXI_GLOB=trips_*.csv.gz  # full ~1.3B trips
# For a quick validation slice, e.g.:
#   HITS_PARTS=0 SSB_SCALE=1 TAXI_GLOB=trips_xaa.csv.gz ./prepare.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${HERE}/data"

DATASETS="${*:-hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"
for ds in ${DATASETS}; do
    echo "================ preparing: ${ds} ================"
    bash "${HERE}/${ds}.sh"
done
echo "All requested datasets prepared under ${HERE}/data/"
