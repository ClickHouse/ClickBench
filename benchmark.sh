#!/bin/bash

set -o noglob
TRIES=5
REPLICAS=3

QUERY_NUM=1

on_cluster=" ON CLUSTER 'default'"

# grab version
version=$(clickhouse client --host "z0ur79yngg.us-central1.gcp.clickhouse-staging.com" --user "${USER:=playbench}" --password "${PASSWORD:=}" --secure --query="SELECT version()")
# check all nodes are available

echo "Waiting for all ${REPLICAS} replicas to be available..."
MAX_RETRIES=30
SLEEP_INTERVAL=5
RETRY_COUNT=0

while true; do
    count=$(clickhouse client \
        --host "z0ur79yngg.us-central1.gcp.clickhouse-staging.com" \
        --user "${USER:=playbench}" \
        --password "${PASSWORD:=}" \
        --secure \
        --query="$REPLICA_CHECK_QUERY" 2>/dev/null)

    if [[ "$count" == "3" ]]; then
        echo "✅ All ${REPLICAS} replicas are available."
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



data_size=$(clickhouse client --host "z0ur79yngg.us-central1.gcp.clickhouse-staging.com" --user "${USER:=playbench}" --password "${PASSWORD:=}" --secure --query="SELECT sum(total_bytes) FROM system.tables WHERE database NOT IN ('system', 'default')")
now=$(date +'%Y-%m-%d')
echo "{\"system\":\"Cloud\",\"date\":\"${now}\",\"machine\":\"720 GB\",\"cluster_size\":3,\"comment\":\"\",\"tags\":[\"Cloud\"],\"version\":\"${version}\",\"data_size\":${data_size},\"result\":[" > temp.json
cat queries.sql | while read query; do
    #clickhouse client --host "${HOST:=localhost}" --user "${USER:=playbench}" --password "${PASSWORD:=}" --secure --format=Null --query="SYSTEM DROP FILESYSTEM CACHE${on_cluster}"
    echo -n "[" >> temp.json
    for i in $(seq 1 $TRIES); do
        RES=$(clickhouse client --host "z0ur79yngg.us-central1.gcp.clickhouse-staging.com" --user "${USER:=playbench}" --password "${PASSWORD:=}" --secure --time --format=Null --query="${query} ${SETTINGS}" 2>&1)
        if [ "$?" == "0" ] && [ "${#RES}" -lt "10" ]; then
            echo "${QUERY_NUM}, ${i} - OK"
            echo -n "${RES}" >> temp.json
        else
            echo "${QUERY_NUM}, ${i} - FAIL - ${RES}"
            echo -n "null" >> temp.json
        fi
        [[ "$i" != $TRIES ]] && echo -n "," >> temp.json
    done
    echo "]," >> temp.json

    QUERY_NUM=$((QUERY_NUM + 1))
done

sed '$ s/.$//' temp.json > results.json
echo ']}' >> results.json
cat results.json | jq > temp.json

set +o noglob
