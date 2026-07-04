#!/bin/bash

# Launch one VM per version (each runs run-benchmark.sh unattended and sends its
# result to the sink). Defaults to every runnable version of the chosen system.
#
#   ./run-all-benchmarks.sh                       # all runnable ClickHouse versions
#   ./run-all-benchmarks.sh 1.1.54378 24.8.1.1
#   system=duckdb ./run-all-benchmarks.sh         # every DuckDB version (duckdb/versions.tsv)
#   system=starrocks ./run-all-benchmarks.sh
#   machine=c6a.metal ./run-all-benchmarks.sh
#
# This fans out across many cloud machines — mind your account's instance/vCPU
# quotas (run-benchmark.sh already retries on capacity/quota errors).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

system="${system:=clickhouse}"
export system

if [ "$#" -gt 0 ]; then
    versions=("$@")
elif [ "${system}" = clickhouse ]; then
    mapfile -t versions < <(./list-versions.sh | awk -F'\t' '$2!="unavailable"{print $1}')
else
    mapfile -t versions < <(awk -F'\t' 'NF && $1!~/^#/{print $1}' "${system}/versions.tsv")
fi

for v in "${versions[@]}"; do
    echo "----------------------------------------- ${system} ${v}"
    ./run-benchmark.sh "${v}" || echo "launch FAILED: ${system} ${v}" >&2
done
