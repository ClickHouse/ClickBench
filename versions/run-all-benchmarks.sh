#!/bin/bash

# Launch one VM per version (each runs run-benchmark.sh unattended and sends its
# result to the sink). Defaults to every runnable version from list-versions.sh.
#
#   ./run-all-benchmarks.sh                  # all runnable versions
#   ./run-all-benchmarks.sh 1.1.54378 24.8.1.1
#   machine=c6a.metal ./run-all-benchmarks.sh
#
# This fans out across many cloud machines — mind your account's instance/vCPU
# quotas (run-benchmark.sh already retries on capacity/quota errors).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"

if [ "$#" -gt 0 ]; then
    versions=("$@")
else
    mapfile -t versions < <(./list-versions.sh | awk -F'\t' '$2!="unavailable"{print $1}')
fi

for v in "${versions[@]}"; do
    echo "----------------------------------------- ${v}"
    ./run-benchmark.sh "${v}" || echo "launch FAILED: ${v}" >&2
done
