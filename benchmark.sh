#!/bin/bash

set -o noglob
TRIES=5


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

settings_json="[\"default\"]"
if [[ -n "$SETTINGS" ]]; then
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
    SETTINGS="SETTINGS ${SETTINGS}"
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

    if [[ "$line" =~ ^--[[:space:]]*\{.*\} ]]; then
        json=$(echo "$line" | sed 's/^--[[:space:]]*//')
        param_flags=""
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
            --query="${query_stmt} ${SETTINGS}" 2>&1)

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
done < queries.sql

sed '$ s/.$//' temp.json > results.json
echo ']}' >> results.json
cat results.json | jq > "$output_file"
rm temp.json results.json
set +o noglob
