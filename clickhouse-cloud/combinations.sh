#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

for i in {1..5}; do

    PARALLEL_REPLICA=false
    MEMORY=0
    PROVIDER=azure
    REGION='eastus2'
    TIER=production

    for MEMORY in 24 48 96 192 360
    do
        export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done


    PARALLEL_REPLICA=false
    MEMORY=0
    PROVIDER=azure
    REGION='germanywestcentral'
    TIER=production

    for MEMORY in 24 48 96 192 360
    do
        export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done

    PARALLEL_REPLICA=false
    MEMORY=0
    PROVIDER=azure
    REGION='westus3'
    TIER=production

    for MEMORY in 24 48 96 192 360
    do
        export PROVIDER TIER REGION MEMORY PARALLEL_REPLICA
        ./cloud-api.sh &
    done

    wait

done
