#!/bin/bash
# Hologres is a managed service of Alibaba Cloud: this runs on a client
# machine in the same VPC as the instance (see README.md), with the
# connection in the environment:
#
#   export PG_USER=... PG_PASSWORD=... PG_HOSTNAME=... PG_PORT=...
#   ./benchmark.sh 1
#
# Nothing to restart, and the caches of the service cannot be dropped: the
# "cold" runs are not cold.
for v in PG_USER PG_PASSWORD PG_HOSTNAME PG_PORT; do
    if [ -z "${!v}" ]; then
        echo "hologres: ${v} is not set, see README.md" >&2
        exit 1
    fi
done
export BENCH_RESTARTABLE=no
export BENCH_MACHINE="${BENCH_MACHINE:-Hologres: 32 CU}"
exec ../lib/benchmark-common.sh "$@"
