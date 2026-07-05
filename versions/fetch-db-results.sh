#!/bin/bash -e

# Fetch the latest Versions Benchmark result for every DuckDB / StarRocks / CedarDB version
# from the sink database (sink.data, kind = "versions-benchmark", sent by the engine cloud-init
# runs on the same c7a.4xlarge machine as ClickHouse) and write <engine>/results/<version>.json.
# The engine payloads already carry system + release_date, so this is a straight copy per
# (system, version), unlike the ClickHouse fetch (fetch-results.sh) which resolves dates and
# renames bare-revision builds. Then regenerate the page data with ./generate-results.sh.
#
#   CONNECTION_PARAMS='--user check_benchmark_results --password *** --host play.clickhouse.com --secure' \
#       ./fetch-db-results.sh

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
CH() { clickhouse-client ${CONNECTION_PARAMS} "$@"; }

# system name in the payload -> its results directory
declare -A DIR=( [DuckDB]=duckdb [StarRocks]=starrocks [CedarDB]=cedardb )

for system in "${!DIR[@]}"; do
    dir="${DIR[$system]}/results"
    mkdir -p "${dir}"
    mapfile -t VERSIONS < <(CH --query "
        SELECT DISTINCT JSONExtractString(content, 'version') AS v
        FROM sink.data
        WHERE JSONExtractString(content, 'kind') = 'versions-benchmark'
          AND JSONExtractString(content, 'system') = '${system}'
          AND v != '' AND length(JSONExtractArrayRaw(content, 'result')) = 344
        ORDER BY v FORMAT TSV")
    echo "fetching ${#VERSIONS[@]} ${system} versions from the sink" >&2
    rm -f "${dir}"/*.json                       # replace with the sink (cloud c7a.4xlarge) set
    for v in "${VERSIONS[@]}"; do
        [ -z "${v}" ] && continue
        CH --query "
            SELECT argMax(content, time) FROM sink.data
            WHERE JSONExtractString(content, 'kind') = 'versions-benchmark'
              AND JSONExtractString(content, 'system') = '${system}'
              AND JSONExtractString(content, 'version') = '${v}'
              AND length(JSONExtractArrayRaw(content, 'result')) = 344
            FORMAT TSVRaw" > /tmp/vb-db-content.json
        # Keep the recorded fields; normalise to compact sorted JSON (system/release_date
        # already present in the payload).
        jq -cS '.' /tmp/vb-db-content.json > "${dir}/${v}.json"
    done
    echo "  wrote $(ls "${dir}"/*.json 2>/dev/null | wc -l) ${system} files" >&2
done
