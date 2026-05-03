#!/bin/bash

TRIES=3

cat queries.sql | while read -r query; do
    # Restart QuestDB so the BE process has no in-memory state and the mmap'd
    # tables are unmapped before drop_caches; otherwise pages mapped by the
    # running JVM are not actually freed and the first run is not cold.
    questdb/bin/questdb.sh stop
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches
    questdb/bin/questdb.sh start

    while ! nc -z localhost 9000; do
      sleep 0.1
    done

    echo "$query";
    for i in $(seq 1 $TRIES); do
        curl -sS --max-time 600 -G --data-urlencode "query=${query}" 'http://localhost:9000/exec?timings=true' 2>&1 | grep '"timings"'
        echo
    done;
done;

questdb/bin/questdb.sh stop
