#!/bin/bash 

set -o noglob
TRIES=5

# Parse extra flag
EXTRA=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --extras)
            EXTRA=$2
            shift 2
            ;;
        *)
            echo "Error: Unknown flag '$1'"
            echo "Usage: $0 [--extras otel]"
            exit 1
            ;;
    esac
done

# Validate extra flag value
if [ "$EXTRA" != "false" ] && [ "$EXTRA" != "otel" ]; then
    echo "Error: Invalid value for --extras flag. Must be 'otel'"
    echo "Usage: $0 [--extras otel]"
    exit 1
fi

cat queries.sql >> queries_tmp.sql

# Generate OTEL parameters if --extra=otel
if [ "$EXTRA" = "otel" ]; then
    echo "Generating OTEL parameters..."
    # Generate timestamps (1 hour difference)
    TS_START=$(date -v-1H +%s000)
    TS_END=$(date +%s000)
    
    # Generate dates
    DATE_NANO=$(date -v-1H +%FT%T.%NZ)
    DATE_MS=$(date -v-1H +%FT%TZ)
    
    # Store OTEL parameters for later merging
    otel_params="--param_HYPERDX_PARAM_TS_START=$TS_START --param_HYPERDX_PARAM_TS_END=$TS_END"
    echo "OTEL parameters generated: $otel_params"
    # Add OTEL queries to the list
    if [ -f "queries_otel.sql" ]; then
        cat queries_otel.sql >> queries_tmp.sql
    fi
fi



# Check that all nodes have the same ClickHouse version
version_check() {
    echo "Checking ClickHouse versions across all nodes..."
    
    local versions_query="SELECT \
        groupUniqArray(version()) AS versions,
        length(groupArray(hostName())) AS nodes_count,
        length(groupUniqArray(version())) AS versions_count
    FROM clusterAllReplicas('default', system.one) SETTINGS skip_unavailable_shards=1"
    
    local result
    result=$(clickhouse client \
        --host "${CLICKHOUSE_HOST}" \
        --user "${CLICKHOUSE_USER:=demobench}" \
        --password "${CLICKHOUSE_PASSWORD:=}" \
        --secure --query="$versions_query" 2>&1)
    
    if [ $? -ne 0 ]; then
        echo "❌ Error checking versions: $result"
        return 1
    fi
    
    # Extract values from result: ['25.6.2.5971']	3	1
    local versions=$(echo "$result" | cut -f1)
    local nodes_count=$(echo "$result" | cut -f2)
    local versions_count=$(echo "$result" | cut -f3)
    
    if [ "$versions_count" != "1" ]; then
        echo "❌ Error: Not all nodes have the same version. Found $versions_count different versions."
        echo "Run this query to see the differences:"
        echo "  SELECT hostName(), version() FROM clusterAllReplicas('default', system.one)"
        return 1
    fi
    
    # Extract just the major.minor version (e.g., 25.6 from 25.6.2.5971)
    local full_version=$(echo "$versions" | tr -d "'[]")
    local minor_version=$(echo "$full_version" | cut -d. -f1-2)
    
    echo "✅ All $nodes_count nodes are running ClickHouse version $full_version"
    echo "Using version: $minor_version"
    
    # Export the version for use in other scripts if needed
    export CLICKHOUSE_VERSION="$minor_version"
}

# Run version check
version_check || exit 1

QUERY_NUM=1
CLICKHOUSE_HOST="${CLICKHOUSE_HOST:=htw00czilh.us-central1.gcp.clickhouse-staging.com}"
on_cluster=" ON CLUSTER 'default'"

# check all nodes are available
echo "Waiting for all ${REPLICAS:=3} replicas to be available..."
MAX_RETRIES=30
SLEEP_INTERVAL=5
RETRY_COUNT=0
REPLICA_CHECK_QUERY="SELECT count() FROM clusterAllReplicas('default', view(SELECT hostname() AS server)) SETTINGS skip_unavailable_shards = 1"

while true; do
    count=$(clickhouse client \
        --host "${CLICKHOUSE_HOST}" \
        --user "${CLICKHOUSE_USER:=demobench}" \
        --password "${CLICKHOUSE_PASSWORD:=}" \
        --secure \
        --query="$REPLICA_CHECK_QUERY" 2>/dev/null)

    if [[ "$count" == "3" ]]; then
        echo "✅ All ${REPLICAS:=3} replicas are available."
        break
    fi

    ((RETRY_COUNT++))
    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
        echo "❌ Timeout: Only $count replicas available after $((MAX_RETRIES * SLEEP_INTERVAL)) seconds."
        exit 1
    fi

    echo "⏳ $count replicas available. Retrying in $SLEEP_INTERVAL seconds..."
    sleep $SLEEP_INTERVAL
done

SETTINGS=${SETTINGS:-}

# Initialize settings_json for output
settings_json="[\"default\"]"

# Process settings if any
if [[ -n "$SETTINGS" ]]; then
    # Convert settings to JSON array for output
    settings_json=$(echo "$SETTINGS" | awk -F',' '
    BEGIN { printf("[") }
    {
        for (i = 1; i <= NF; i++) {
            setting = $i
            gsub(/^ +| +$/, "", setting)  # trim leading/trailing spaces
            gsub(/"/, "\\\"", setting)   # escape double quotes
            printf("\"%s\"", setting)
            if (i < NF) printf(",")
        }
    }
    END { printf("]") }')
    
    # Convert settings to individual --key=value parameters
    query_settings=$(echo "$SETTINGS" | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/^/--/' | tr '\n' ' ')
fi

echo "${SETTINGS}"

# grab version
version=$(clickhouse client --host "${CLICKHOUSE_HOST}" --user "${CLICKHOUSE_USER:=demobench}" --password "${CLICKHOUSE_PASSWORD:=}" --secure --query="SELECT version()")
data_size=$(clickhouse client --host "${CLICKHOUSE_HOST}" --user "${CLICKHOUSE_USER:=demobench}" --password "${CLICKHOUSE_PASSWORD:=}" --secure --query="SELECT sum(total_bytes) FROM system.tables WHERE database NOT IN ('system', 'default')")
timestamp=$(date +'%Y-%m-%d-%H-%M-%S')
output_file="${timestamp}.json"

echo "{\"system\":\"Cloud\",\"date\":\"${timestamp}\",\"machine\":\"720 GB\",\"cluster_size\":3,\"comment\":\"\",\"settings\":${settings_json},\"version\":\"${version}\",\"data_size\":${data_size},\"result\":[" > temp.json

param_flags=""
query_stmt=""

while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" ]] && continue
    param_flags="$otel_params"
    if [[ "$line" =~ ^--[[:space:]]*\{.*\} ]]; then
        json=$(echo "$line" | sed 's/^--[[:space:]]*//')
        # Start with OTEL params if they exist
        while IFS="=" read -r key value; do
            param_flags+="--param_${key}=${value} "
        done < <(echo "$json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
        continue
    fi

    echo $param_flags

    query_stmt="$line"
    [[ -z "$query_stmt" || "$query_stmt" =~ ^-- ]] && continue
    echo $query_stmt
    # Drop cache
    while true; do
        echo "Dropping Cache..."
        clickhouse client --host "${CLICKHOUSE_HOST}" --user "${CLICKHOUSE_USER}" --password "${CLICKHOUSE_PASSWORD}" --secure --format=Null --query="SYSTEM DROP FILESYSTEM CACHE${on_cluster}" && break
        echo "⏳ Retrying SYSTEM DROP FILESYSTEM CACHE..."
        sleep 2
    done

    echo -n "[" >> temp.json
    for j in $(seq 1 $TRIES); do
        RES=$(clickhouse client \
            --host "${CLICKHOUSE_HOST}" \
            --user "${CLICKHOUSE_USER}" \
            --password "${CLICKHOUSE_PASSWORD}" \
            --secure \
            --time \
            --format=Null \
            $param_flags \
            --compatibility ${CLICKHOUSE_VERSION} \
            $query_settings \
            --query="${query_stmt}" 2>&1)

        if [ "$?" == "0" ] && [ "${#RES}" -lt "10" ]; then
            echo "${QUERY_NUM}, ${j} - OK"
            echo -n "${RES}" >> temp.json
        else
            echo "${QUERY_NUM}, ${j} - FAIL - ${RES}"
            echo -n "null" >> temp.json
        fi
        [[ "$j" != $TRIES ]] && echo -n "," >> temp.json
    done
    echo "]," >> temp.json

    QUERY_NUM=$((QUERY_NUM + 1))
done < queries_tmp.sql

sed '$ s/.$//' temp.json > results.json
echo ']}' >> results.json
cat results.json | jq > "$output_file"
rm temp.json results.json queries_tmp.sql
set +o noglob
