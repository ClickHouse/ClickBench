#!/bin/bash

TRIES=3

cat queries.sql | while read query; do
  sync
  # echo 3 | sudo tee /proc/sys/vm/drop_caches

  echo "$query";
  for i in $(seq 1 $TRIES); do
  psql -X 'postgresql://postgres:S9PPuI4kly8Rs0yu@peevishly-conclusive-nighthawk.data-1.use1.tembo-development.com:5432/postgres' -c '\timing' -c "$query" | grep 'Time'
  done;
done;
