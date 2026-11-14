#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='ap-southeast-2'
PARALLEL_REPLICA=false

# The Scale tier supports single-replica services of every size,
# so all replica counts run over the full range of memory sizes.
for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 120 236 356
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
        sleep 10 # Prevent "Too many requests" to the API
    done
done

PROVIDER=gcp
REGION='us-east1'

for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 120 236 356
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
        sleep 10
    done
done

PROVIDER=azure
REGION='westus3'

for REPLICAS in 1 2 3
do
    for MEMORY in 8 12 16 32 64 120 236 356
    do
        export PROVIDER REPLICAS REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
        sleep 10
    done
done

wait
