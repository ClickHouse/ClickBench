#!/bin/bash

# export ORGANIZATION=...
# export KEY_ID=...
# export KEY_SECRET=...

PROVIDER=aws
REGION='eu-central-1'

TIER=development
MEMORY=0
export PROVIDER TIER REGION MEMORY
./cloud-api.sh &

TIER=production
for MEMORY in 24 48 96 192 360 720
do
    export PROVIDER TIER REGION MEMORY
    ./cloud-api.sh &
done

PROVIDER=gcp
REGION='europe-west4'

TIER=development
MEMORY=0
export PROVIDER TIER REGION MEMORY
./cloud-api.sh &

TIER=production
for MEMORY in 24 48 96 192 360 708
do
    export PROVIDER TIER REGION MEMORY
    ./cloud-api.sh &
done
