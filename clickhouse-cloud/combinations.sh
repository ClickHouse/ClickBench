#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

for PROVIDER in aws gcp
do
    if [ "$PROVIDER" == 'aws' ]
    then
        REGION='eu-central-1'
    else
        REGION='europe-west-4'
    fi

    TIER=development
    MEMORY=0
    export PROVIDER TIER REGION MEMORY
    ./cloud-api.sh

    TIER=production
    for MEMORY in 24 48 96 192 360 720
    do
        export PROVIDER TIER REGION MEMORY
        ./cloud-api.sh
    done
done
