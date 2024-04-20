#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='eu-central-1'

TIER=development
MEMORY=0

# Handle Parralel replica
PARALLEL_REPLICA=true

export PROVIDER TIER REGION MEMORY PARRALEL_REPLICA
./cloud-api.sh &

# Disable parallel replica for the remaining of the benchmark for AWS
PARALLEL_REPLICA=false

./cloud-api.sh &

TIER=production
for MEMORY in 24 48 96 192 360 720
do
    export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
    ./cloud-api.sh &
done

PROVIDER=gcp
REGION='europe-west4'

TIER=development
MEMORY=0

# Handle Paralel replica for GCP
PARALLEL_REPLICA=true

export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
./cloud-api.sh &

# Disable parallel replica for the remaining of the benchmark for AWS
PARALLEL_REPLICA=false

TIER=production
for MEMORY in 24 48 96 192 360 708
do
    export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
    ./cloud-api.sh &
done
