#!/bin/bash

cat queries.sql | sed -r -e 's@hits@dfs.`/hits.parquet`@g' | while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    echo "${query}"
    sudo docker run -i --rm --name drill -v $(pwd)/hits.parquet:/hits.parquet apache/drill <<< "${query}"$'\r'"${query}"$'\r'"${query}"$'\r'
    echo
done
