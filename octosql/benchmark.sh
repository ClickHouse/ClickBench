#!/bin/bash

wget --continue --progress=dot:giga https://github.com/cube2222/octosql/releases/download/v0.13.0/octosql_0.13.0_linux_amd64.tar.gz
tar xf octosql_0.13.0_linux_amd64.tar.gz

../lib/download-parquet.sh

./run.sh 2>&1 | tee log.txt

cat log.txt |
  grep -P '^real|^Error|^Killed|^fatal error|^panic' |
  sed -r -e 's/^(Error|Killed|fatal|panic).*$/null/; s/^real\s*([0-9.]+)m([0-9.]+)s$/\1 \2/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if ($1 == "null") { skip = 1 } else { if (i % 3 == 0) { printf "[" }; printf skip ? "null" : $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; skip = 0; } }'

echo "Data size: $(du -b hits.parquet)"
echo "Load time: 0"
