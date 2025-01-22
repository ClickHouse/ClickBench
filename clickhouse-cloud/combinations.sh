#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='us-east-1'
PARALLEL_REPLICA=false

for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 128 256
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done
done

PROVIDER=gcp
REGION='us-east1'

for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 128 256
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done
done

PROVIDER=azure
REGION='eastus2'

for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 128 256
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done
done

wait
