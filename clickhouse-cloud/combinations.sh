#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='us-east-1'
PARALLEL_REPLICA=false

TIER=development
MEMORY=0

export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
./cloud-api.sh &

TIER=production
for MEMORY in 24 48 96 192 360 720
do
    export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
    ./cloud-api.sh &
done

PROVIDER=gcp
REGION='us-east1'

TIER=development
MEMORY=0

export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
./cloud-api.sh &

TIER=production
for MEMORY in 24 48 96 192 360 708
do
    export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
    ./cloud-api.sh &
done

PROVIDER=azure
REGION='eastus2'

TIER=production
for MEMORY in 24 48 96 192 360 708
do
    export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
    ./cloud-api.sh &
done

wait
