#!/bin/bash

# Define the base URL and Authorization token
BASE_URL="https://api.tinybird.co/v0/pipes/"
AUTH_HEADER=<TOKEN>

results="["

for i in {1..43}; do
    times=()
    for j in {1..3}; do
        response=$(curl -s --compressed -H "$AUTH_HEADER" "${BASE_URL}Q${i}.json")

        elapsed=$(echo "$response" | jq '.statistics.elapsed')
        echo "$elapsed"
        times+=($elapsed)
    done
    results+=$(printf "[%s,%s,%s]," "${times[0]}" "${times[1]}" "${times[2]}")
done

results=${results%,}
results+="]"

echo "$results"
