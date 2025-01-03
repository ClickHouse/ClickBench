#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=${PROVIDER:-aws}
REGION=${REGION:-eu-central-1}
TIER=${TIER:-development}
MEMORY=${MEMORY:-0}
PARALLEL_REPLICA=${PARALLEL_REPLICA:-false}

command -v jq || exit 1
command -v curl || exit 1
command -v clickhouse-client || exit 1

echo "Provisioning a service in ${PROVIDER}, region ${REGION}, ${TIER} tier, memory ${MEMORY}, with parallel replicas set to ${PARALLEL_REPLICA}"

TMPDIR="${PROVIDER}-${REGION}-${TIER}-${MEMORY}-${PARALLEL_REPLICA}-$$"
mkdir -p "${TMPDIR}"

echo $TMPDIR

curl -X POST -H 'Content-Type: application/json' -d '
{
    "name": "ClickBench-'${PROVIDER}'-'${REGION}'-'${TIER}'-'${MEMORY}'-'$$'",
    "tier": "'$TIER'",
    "provider": "'$PROVIDER'",
    "region": "'$REGION'",
    '$([ $TIER == production ] && echo -n "\"minTotalMemoryGb\":${MEMORY},\"maxTotalMemoryGb\":${MEMORY},")'
    "ipAccessList": [{"source": "0.0.0.0/0", "description": "anywhere"}]
}
' --silent --show-error --user "${KEY_ID}:${KEY_SECRET}" "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services" | tee "${TMPDIR}"/service.json | jq | grep -v password

echo ${KEY_ID}:${KEY_SECRET}" "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services

[ $(jq .status "${TMPDIR}"/service.json) != 200 ] && exit 1

export SERVICE_ID=$(jq --raw-output .result.service.id "${TMPDIR}"/service.json)
export FQDN=$(jq --raw-output .result.service.endpoints[0].host "${TMPDIR}"/service.json)
export PASSWORD=$(jq --raw-output .result.password "${TMPDIR}"/service.json)

echo "Waiting for it to start"

for i in {0..1000}
do
    echo -n "$i seconds... "
    curl --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq --raw-output .result.state | tee "${TMPDIR}"/state
    grep 'running' "${TMPDIR}"/state && break
    sleep 1
    if [[ $i == 1000 ]]
    then
        echo "Too many retries"
        exit 1
    fi
done

echo "Waiting for clickhouse-server to start"

for i in {1..1000}
do
    clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT 1" && break
    sleep 1
    if [[ $i == 1000 ]]
    then
        echo "Too many retries"
        exit 1
    fi
done

if [ ${PARALLEL_REPLICA} = true ]; then
   echo "Enabling parallel replica to the default user"
   clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "ALTER USER default SETTINGS allow_experimental_parallel_reading_from_replicas=2;"
fi

echo "Running the benchmark"

./benchmark.sh 2>&1 | tee "${TMPDIR}"/result

echo "Stopping the service"

curl -X PATCH -H 'Content-Type: application/json' -d '{"command": "stop"}' --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}/state" | jq

echo "Waiting for the service to stop"

for i in {0..1000}
do
    echo -n "$i seconds... "
    curl --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq --raw-output .result.state | tee "${TMPDIR}"/state
    grep 'stopped' "${TMPDIR}"/state && break
    sleep 1
    if [[ $i == 1000 ]]
    then
        echo "Too many retries"
        exit 1
    fi
done

echo "Deleting the service"

curl -X DELETE --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq
