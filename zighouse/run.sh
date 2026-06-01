#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CLICKBENCH_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

: "${ZIGHOUSE_REPO:?Set ZIGHOUSE_REPO to the ZigHouse repository path}"
ZIGHOUSE_STORE=${ZIGHOUSE_STORE:-"${SCRIPT_DIR}/zighouse-store"}
TRIES=${TRIES:-3}

queries_file="${SCRIPT_DIR}/queries.sql"
if [ ! -f "${queries_file}" ]; then
    queries_file="${CLICKBENCH_DIR}/duckdb/queries.sql"
fi

ZIGHOUSE_CLICKBENCH_SUBMIT=1 "${ZIGHOUSE_REPO}/zig-out/bin/zighouse" --backend native bench "${ZIGHOUSE_STORE}" "${queries_file}" \
    | grep '^\['
