#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='us-east-1'
PARALLEL_REPLICA=false

# Optional cap on parallel jobs; set MAX_PARALLEL=N in the environment to enable.
throttle() {
    local max=${MAX_PARALLEL:-0}
    if [[ -n "$max" && "$max" =~ ^[0-9]+$ && $max -gt 0 ]]; then
        while [[ $(jobs -rp | wc -l) -ge $max ]]; do
            sleep 1
        done
    fi
}

for REPLICAS in 1
do
    for MEMORY in 8 12
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10 # Prevent "Too many requests" to the API
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120 236
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10
    done
done

PROVIDER=gcp
REGION='us-east1'

for REPLICAS in 1
do
    for MEMORY in 8 12
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120 236
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10
    done
done

PROVIDER=azure
REGION='eastus2'

for REPLICAS in 1
do
    for MEMORY in 8 12
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
    throttle; ./cloud-api.sh &
        sleep 10
    done
done

wait
