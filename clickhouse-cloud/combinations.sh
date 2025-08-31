#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='us-east-1'
PARALLEL_REPLICA=false

for REPLICAS in 1
do
    for MEMORY in 8 12
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
        sleep 10 # Prevent "Too many requests" to the API
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120 236
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
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
        ./cloud-api.sh &
        sleep 10
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120 236
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
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
        ./cloud-api.sh &
        sleep 10
    done
done

for REPLICAS in 2 3
do
    for MEMORY in 8 12 16 32 64 120
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
        sleep 10
    done
done

wait
