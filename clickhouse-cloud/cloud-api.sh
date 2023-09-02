#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=${PROVIDER:-aws}
REGION=${REGION:-eu-central-1}
TIER=${TIER:-production}
MEMORY=${MEMORY:-48}

command -v jq || exit 1
command -v curl || exit 1
command -v clickhouse-client || exit 1

echo "Provisioning a service in ${PROVIDER}, region ${REGION}, ${TIER} tier, memory ${MEMORY}"

curl -X POST -H 'Content-Type: application/json' -d '
{
    "name": "ClickBench-'${PROVIDER}'-'${REGION}'-'${TIER}'-'${MEMORY}'",
    "tier": "'$TIER'",
    "provider": "'$PROVIDER'",
    "region": "'$REGION'",
    '$([ $TIER == production ] && echo -n "\"minTotalMemoryGb\":${MEMORY},\"maxTotalMemoryGb\":${MEMORY},")'
    "ipAccessList": [{"source": "0.0.0.0/0", "description": "anywhere"}]
}
' --silent --show-error --user "${KEY_ID}:${KEY_SECRET}" "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services" | tee service.json | jq

[ $(jq .status service.json) != 200 ] && exit 1

export SERVICE_ID=$(jq --raw-output .result.service.id service.json)
export FQDN=$(jq --raw-output .result.service.endpoints[0].host service.json)
export PASSWORD=$(jq --raw-output .result.password service.json)

echo "Waiting for it to start"

for i in {0..1000}
do
    echo -n "$i seconds... "
    curl --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq --raw-output .result.state | tee state
    grep 'running' state && break
    sleep 1
done

echo "Waiting for clickhouse-server to start"

for _ in {1..1000}
do
    clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT 1" && break
    sleep 1
done

echo "Running the benchmark"

./benchmark.sh

echo "Stopping the service"

curl -X PATCH -H 'Content-Type: application/json' -d '{"command": "stop"}' --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}/state" | jq

echo "Waiting for the service to stop"

for i in {0..1000}
do
    echo -n "$i seconds... "
    curl --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq --raw-output .result.state | tee state
    grep 'stopped' state && break
    sleep 1
done

echo "Deleting the service"

curl -X DELETE --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${SERVICE_ID}" | jq
