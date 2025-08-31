#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=${PROVIDER:-aws}
REGION=${REGION:-eu-central-1}
MEMORY=${MEMORY:-8}
REPLICAS=${REPLICAS:-2}
PARALLEL_REPLICA=${PARALLEL_REPLICA:-false}

command -v jq || exit 1
command -v curl || exit 1
command -v clickhouse-client || exit 1

NAME_PREFIX="ClickBench-${PROVIDER}-${REGION}-${REPLICAS}-${MEMORY}"
NAME_FULL="${NAME_PREFIX}-$$"

TMPDIR="csp-${PROVIDER}-region-${REGION}-replicas-${REPLICAS}-memory-${MEMORY}-parallel-${PARALLEL_REPLICA}-pid-$$"
mkdir -p "${TMPDIR}"

echo $TMPDIR

curl -X GET -H 'Content-Type: application/json' --silent --show-error --user "${KEY_ID}:${KEY_SECRET}" "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services" | jq .result \
| ch --input-format JSONEachRow --query "SELECT id FROM table WHERE startsWith(name, '${NAME_PREFIX}')" \
| while read -r OLD_SERVICE_ID
do
    echo "Found an old service, ${OLD_SERVICE_ID}. Stopping it."
    curl -X PATCH -H 'Content-Type: application/json' -d '{"command": "stop"}' --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${OLD_SERVICE_ID}/state" | jq
    echo "Waiting for the service to stop"

    for i in {0..1000}
    do
        echo -n "$i seconds... "
        curl --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${OLD_SERVICE_ID}" | jq --raw-output .result.state | tee "${TMPDIR}"/state
        grep 'stopped' "${TMPDIR}"/state && break
        sleep 1
        if [[ $i == 1000 ]]
        then
            echo "Too many retries"
            exit 1
        fi
    done

    echo "Deleting the service"
    curl -X DELETE --silent --show-error --user $KEY_ID:$KEY_SECRET "https://api.clickhouse.cloud/v1/organizations/${ORGANIZATION}/services/${OLD_SERVICE_ID}" | jq
done

echo "Provisioning a service in ${PROVIDER}, region ${REGION}, memory ${MEMORY}, replicas ${REPLICAS}, with parallel replicas set to ${PARALLEL_REPLICA}"

curl -X POST -H 'Content-Type: application/json' -d '
{
    "name": "'${NAME_FULL}'",
    "provider": "'$PROVIDER'",
    "region": "'$REGION'",
    "releaseChannel": "fast",
    "numReplicas": '$REPLICAS',
    "minReplicaMemoryGb":'$MEMORY',"maxReplicaMemoryGb":'$MEMORY',
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

# Collect quick network/TLS diagnostics for this run
{
    echo "==== NET DEBUG $(date -Iseconds) ===="
    echo "Host: $(hostname)"
    echo "Kernel: $(uname -a)"
    echo "ulimit -n: $(ulimit -n 2>/dev/null || echo n/a)"
    echo "FQDN: ${FQDN}"
    echo "IP route:"; ip route || true
    echo "IP addr:"; ip -brief address || ip addr || true
    echo "DNS resolution for ${FQDN}:"; getent hosts "${FQDN}" || nslookup "${FQDN}" 2>&1 || host "${FQDN}" 2>&1 || true
    echo "Socket summary:"; ss -s || true
    echo "Public IP (best-effort):"; curl -fsS --max-time 3 https://ifconfig.me || echo "n/a"
    echo "OpenSSL s_client (short):"; timeout 10s openssl s_client -connect "${FQDN}:9440" -servername "${FQDN}" -brief </dev/null 2>&1 || true
    echo "Traceroute TCP:9440:"; timeout 20s traceroute -T -p 9440 -n "${FQDN}" 2>&1 || traceroute -n "${FQDN}" 2>&1 || true
} > "${TMPDIR}/netdebug.txt" 2>&1

for i in {1..1000}
do
    if clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT 1" 1>/dev/null 2>>"${TMPDIR}/chclient_errors.log"; then
        break
    fi
    sleep 1
    if [[ $i == 1000 ]]
    then
        echo "Too many retries"
        exit 1
    fi
done

if [ ${PARALLEL_REPLICA} = true ]; then
    echo "Enabling parallel replica to the default user"
    clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "ALTER USER default SETTINGS enable_parallel_replicas = 1"
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
