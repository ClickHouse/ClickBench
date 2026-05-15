#!/usr/bin/env bash

set -euo pipefail

if [[ -x /usr/local/bin/bh-repro && "${BH_REPRO_BYPASS:-0}" != "1" ]]; then
    exec sudo /usr/local/bin/bh-repro benchmark "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

LOCK_FILE="${BENCHMARK_LOCK_FILE:-${SCRIPT_DIR}/.benchmark.lock}"
LOCK_DIR=""
LOCK_FD=""

source "${SCRIPT_DIR}/common.sh"

acquire_lock() {
    mkdir -p "$(dirname "${LOCK_FILE}")"

    if command -v flock >/dev/null 2>&1; then
        exec {LOCK_FD}>"${LOCK_FILE}"
        if ! flock -n "${LOCK_FD}"; then
            echo "Another ./benchmark.sh process is already running (lock: ${LOCK_FILE})." >&2
            exit 1
        fi
        return 0
    fi

    LOCK_DIR="${LOCK_FILE}.d"
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        printf '%s\n' "$$" > "${LOCK_DIR}/pid"
        return 0
    fi

    if [[ -f "${LOCK_DIR}/pid" ]]; then
        local owner_pid
        owner_pid="$(<"${LOCK_DIR}/pid")"
        if [[ -n "${owner_pid}" ]] && ! kill -0 "${owner_pid}" 2>/dev/null; then
            rm -rf "${LOCK_DIR}"
            if mkdir "${LOCK_DIR}" 2>/dev/null; then
                printf '%s\n' "$$" > "${LOCK_DIR}/pid"
                return 0
            fi
        fi
    fi

    echo "Another ./benchmark.sh process is already running (lock: ${LOCK_FILE})." >&2
    exit 1
}

cleanup() {
    if [[ "${CLEANUP_SERVER_ON_EXIT}" == "1" ]]; then
        bytehouse::stop_server
    fi

    if [[ -n "${LOCK_DIR}" ]]; then
        rm -rf "${LOCK_DIR}"
    fi

    if [[ -n "${LOCK_FD}" ]] && command -v flock >/dev/null 2>&1; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
    fi
}

acquire_lock
trap cleanup EXIT

bytehouse::setup_runtime
bytehouse::download_data_if_needed

bytehouse::start_server
bytehouse::create_table

echo -n "Load time: "
bytehouse::load_data

"${SCRIPT_DIR}/run.sh"

echo "Data size: $(bytehouse::table_size_bytes)"
