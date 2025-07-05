#!/bin/bash

export YT_USE_HOSTS=0
export CHYT_ALIAS=*ch_public

echo "----------------"
# Create table
echo "Creating table"
command time -f '%e' yt clickhouse execute "$(cat create.sql)" --alias $CHYT_ALIAS --proxy $YT_PROXY
echo "----------------"

echo "----------------"
# Fill table
echo -n "Load time: "
command time -f '%e' yt clickhouse execute "$(cat fill_data.sql)" --alias $CHYT_ALIAS --proxy $YT_PROXY
echo "----------------"

echo "----------------"
# Sort table
echo -n "Load time: "
command time -f '%e' yt sort --src //home/hits --dst //home/hits --sort-by "CounterID" --sort-by "EventDate" --sort-by "UserID" --sort-by "EventTime" --sort-by "WatchID" --proxy $YT_PROXY
echo "----------------"

echo "----------------"
# Run benchmark
echo "Starting benchmark"
./run.sh
echo "----------------"
