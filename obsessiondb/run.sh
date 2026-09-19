#!/bin/bash

TRIES=3
sed -n 'p;p;p' queries.sql |
clickhouse-client --host "${FQDN:=localhost}" --password "${PASSWORD:=}" ${PASSWORD:+--secure} --time --format Null ${EXTRA_SETTINGS} 2>&1 |
grep -o -P '^\d+\.\d+$' | awk '{ a[NR%3]=$0 } NR%3==0 { printf "[%s, %s, %s],\n", a[1], a[2], a[0] }'
