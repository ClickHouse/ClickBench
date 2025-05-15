#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches

    for i in $(seq 1 $TRIES); do
        # Apparently, cockroach sql only writes the elapsed time of a statement to file descriptors that refer to a terminal (cf. isatty()).
        # Since we *pipe* the output into grep, we need to use unbuffer.
        unbuffer cockroach sql --insecure --host=localhost --database=test --execute="${query}" | grep 'Time'
    done;
done;
