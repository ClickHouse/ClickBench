#!/bin/bash

# Shared JSONBench driver.
#
# A per-system benchmark.sh sets a few env vars and then exec's this script:
#
#   #!/bin/bash
#   export BENCH_RESTARTABLE=yes
#   exec ../lib/benchmark-common.sh "$@"
#
# Usage (from a system directory such as json/clickhouse/):
#
#   ./benchmark.sh <size>
#
# where <size> is the dataset size in millions of documents: 1, 10, 100 or
# 1000. The dataset is the Bluesky event stream: file_0001.json.gz ...
# file_1000.json.gz, one million newline-delimited JSON documents each, and a
# size of N means the first N files.
#
# It follows the main ClickBench driver (../../lib/benchmark-common.sh) and
# uses the same per-system scripts, all relative to the system directory:
#
#   install     install the system (no arguments).
#   start       start the server; a no-op for embedded engines.
#   check       exit 0 when the system is ready to accept queries.
#   stop        stop the server; a no-op for embedded engines.
#   load        create the table and load the data. The environment carries
#               BENCH_DATA_DIR (the directory with the .json.gz files) and
#               BENCH_FILES (how many of them to load, the files are named
#               file_0001.json.gz and so on, so `ls | head -n` picks them).
#               Should be idempotent: it is re-run for BENCH_DURABLE=no.
#   query       read one query from stdin, run it, print the result to stdout
#               and the runtime in fractional seconds as the last line of
#               stderr; exit non-zero on error.
#   data-size   print the size of the stored data in bytes (data + indexes).
#   count       print the number of loaded documents.
#   version     optional: print the version of the system.
#   template.json  static metadata of the entry: system, retains_structure,
#               tags, and optionally proprietary, comment.
#   queries.sql (or BENCH_QUERIES_FILE) - the queries, one per line.
#
# The driver prints the same log lines as the main ClickBench driver
# ("Load time:", "Data size:", "[t1,t2,t3],") and in addition writes the
# complete result document to result.json, framed in the log between
# "=== JSONBench result ===" and "=== end of JSONBench result ===".
# cloud-init.sh.in sends result.json to the sink.
#
# Optional env:
#   BENCH_RESTARTABLE  yes (default) / no, see ../../lib/benchmark-common.sh.
#   BENCH_DURABLE      yes (default) / no, see ../../lib/benchmark-common.sh.
#   BENCH_TRIES        number of runs of every query, default 3.
#   BENCH_QUERIES_FILE default queries.sql.
#   BENCH_CHECK_TIMEOUT seconds to wait for ./check, default 300.
#   BENCH_DATA_DIR     where the dataset files are, default /data/bluesky.
#                      It is world-readable, so that the servers running as
#                      their own users (postgres, mongodb, ...) can read it.
#   BENCH_MACHINE      the machine description for the result, default: the
#                      EC2 instance type from the instance metadata service.
#   BENCH_QUERY_TIMEOUT seconds for one run of a query. A run that exceeds it
#                      is recorded as null, and so are the remaining runs of
#                      that query. Default: 3600, 7200 for the 100m size and
#                      36000 for 1000m (MongoDB and PostgreSQL took up to
#                      9 hours for a single query on 1000m).

set -e

export HOME="${HOME:-/root}"

: "${BENCH_RESTARTABLE:=yes}"
: "${BENCH_DURABLE:=yes}"
: "${BENCH_TRIES:=3}"
: "${BENCH_QUERIES_FILE:=queries.sql}"
: "${BENCH_CHECK_TIMEOUT:=300}"
: "${BENCH_DATA_DIR:=/data/bluesky}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON_DIR="$(dirname "${LIB_DIR}")"

BENCH_SIZE="${1:-${BENCH_SIZE:-}}"
case "${BENCH_SIZE}" in
    1|10|100|1000) ;;
    *) echo "usage: $0 <size in millions of documents: 1, 10, 100 or 1000>" >&2; exit 1 ;;
esac
export BENCH_SIZE
case "${BENCH_SIZE}" in
    1000) : "${BENCH_QUERY_TIMEOUT:=36000}" ;;
    100)  : "${BENCH_QUERY_TIMEOUT:=7200}" ;;
    *)    : "${BENCH_QUERY_TIMEOUT:=3600}" ;;
esac
export BENCH_FILES="${BENCH_SIZE}"
export BENCH_DATA_DIR

bench_check_loop() {
    local i last_err
    for i in $(seq 1 "$BENCH_CHECK_TIMEOUT"); do
        if last_err=$(./check 2>&1 >/dev/null); then
            return 0
        fi
        sleep 1
    done
    echo "bench: ./check did not succeed within ${BENCH_CHECK_TIMEOUT}s" >&2
    if [ -n "$last_err" ]; then
        echo "bench: last ./check stderr was:" >&2
        printf '%s\n' "$last_err" | sed 's/^/    /' >&2
    fi
    return 1
}

# Wait until ./check fails, i.e. the system is really down: engines that mmap
# their files keep the page cache pinned until the process is gone.
bench_wait_stopped() {
    local i
    for i in $(seq 1 60); do
        if ! ./check >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "bench: system did not stop within 60s; proceeding anyway" >&2
    return 0
}

bench_flush_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    if [ -x ./flush-caches ]; then
        ./flush-caches >/dev/null 2>&1 || true
    fi
}

bench_cold_cycle() {
    if [ "$BENCH_RESTARTABLE" = "yes" ]; then
        ./stop >/dev/null 2>&1 || true
        bench_wait_stopped
        bench_flush_caches
        ./start >/dev/null 2>&1 || true
        bench_check_loop
    else
        bench_flush_caches
    fi
}

# See bench_wait_fs_init in ../../lib/benchmark-common.sh.
bench_wait_fs_init() {
    local waited=0 limit=900
    while [ "$waited" -lt "$limit" ]; do
        if ! grep -qsx 'ext4lazyinit' /proc/[0-9]*/comm; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    if [ "$waited" -gt 0 ]; then
        echo "bench: waited ${waited}s for ext4lazyinit to finish before the load" >&2
    fi
}

bench_extract_timing() {
    printf '%s\n' "$1" | tr '\r' '\n' | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -n1
}

LOAD_TIME=null

bench_load() {
    local start_t end_t
    start_t=$(date +%s.%N)
    ./load
    # The data must be on disk before the timer stops, and before the first
    # cold query, which would otherwise pay for the writeback.
    sync
    end_t=$(date +%s.%N)
    LOAD_TIME=$(awk -v s="$start_t" -v e="$end_t" 'BEGIN { printf "%.3f", e - s }')
    echo "Load time: ${LOAD_TIME}"

    if ! ./check >/dev/null 2>&1; then
        echo "bench: ./check failed after ./load - server crashed mid-load?" >&2
        return 1
    fi
}

RESULT_LINES=()

bench_run_query() {
    local query="$1" query_num="$2"
    local i raw_stderr exit_code timing load_secs=0
    local results=()

    bench_cold_cycle

    if [ "$BENCH_DURABLE" != "yes" ]; then
        local load_start load_end
        load_start=$(date +%s.%N)
        ./load >/dev/null 2>&1
        load_end=$(date +%s.%N)
        load_secs=$(awk -v s="$load_start" -v e="$load_end" 'BEGIN{printf "%.6f", e - s}')
    fi

    for i in $(seq 1 "$BENCH_TRIES"); do
        raw_stderr=$(printf '%s\n' "$query" | timeout "$BENCH_QUERY_TIMEOUT" ./query 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
        if [ "$exit_code" -eq 0 ]; then
            timing=$(bench_extract_timing "$raw_stderr")
            [ -z "$timing" ] && timing="null"
        else
            timing="null"
            printf '%s\n' "$raw_stderr" | tail -n 20 >&2
            if [ "$exit_code" -eq 124 ]; then
                echo "bench: query ${query_num} exceeded ${BENCH_QUERY_TIMEOUT}s" >&2
            fi
        fi
        if [ "$i" -eq 1 ] && [ "$BENCH_DURABLE" != "yes" ] && [ "$timing" != "null" ]; then
            timing=$(awk -v t="$timing" -v l="$load_secs" 'BEGIN{printf "%.3f", t + l}')
        fi
        results+=("$timing")
        # A query that timed out will time out again: don't spend hours on it.
        if [ "$exit_code" -eq 124 ]; then
            while [ "${#results[@]}" -lt "$BENCH_TRIES" ]; do results+=("null"); done
            break
        fi
    done

    local out
    out="[$(IFS=,; echo "${results[*]}")]"
    RESULT_LINES+=("$out")
    echo "${out},"
}

bench_machine() {
    if [ -n "${BENCH_MACHINE:-}" ]; then
        echo "${BENCH_MACHINE}"
        return
    fi
    local token
    token=$(curl -fsS --connect-timeout 1 --max-time 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        'http://169.254.169.254/latest/api/token' 2>/dev/null) || { hostname; return; }
    curl -fsS --connect-timeout 1 --max-time 2 -H "X-aws-ec2-metadata-token: ${token}" \
        'http://169.254.169.254/latest/meta-data/instance-type' 2>/dev/null || hostname
}

bench_main() {
    local system_dir
    system_dir=$(basename "$PWD")
    echo "JSONBench system: ${system_dir}, dataset size: ${BENCH_SIZE}m"

    ./install
    sync
    bench_start_quiet

    "${JSON_DIR}/download-data" "${BENCH_SIZE}" "${BENCH_DATA_DIR}"
    sync
    bench_wait_fs_init
    bench_load

    local num_loaded
    num_loaded=$(./count 2>/dev/null | tail -n1 | tr -d '[:space:]')
    if ! [[ "$num_loaded" =~ ^[0-9]+$ ]]; then
        echo "bench: ./count printed '${num_loaded}', not a number" >&2
        num_loaded=null
    fi
    echo "Loaded documents: ${num_loaded}"
    if [ "$num_loaded" = "null" ] || [ "$num_loaded" -eq 0 ]; then
        echo "bench: nothing was loaded" >&2
        return 1
    fi

    local query_num=1 query
    while IFS= read -r query || [ -n "$query" ]; do
        [ -z "$query" ] && continue
        bench_run_query "$query" "$query_num"
        query_num=$((query_num + 1))
    done < "$BENCH_QUERIES_FILE"

    local data_size
    data_size=$(./data-size | tail -n1 | tr -d '[:space:]')
    [[ "$data_size" =~ ^[0-9]+$ ]] || data_size=null
    echo "Data size: ${data_size}"

    local version=""
    if [ -x ./version ]; then
        version=$(./version 2>/dev/null | tail -n1 | tr -d '\r') || version=""
    fi

    bench_stop_quiet

    local os
    os=$(. /etc/os-release && echo "${NAME} ${VERSION_ID}")

    printf '%s\n' "${RESULT_LINES[@]}" | jq -s -c \
        --slurpfile template template.json \
        --arg version "$version" \
        --arg os "$os" \
        --arg date "$(date -u +%F)" \
        --arg machine "$(bench_machine)" \
        --argjson dataset_size "$((BENCH_SIZE * 1000000))" \
        --argjson num_loaded_documents "$num_loaded" \
        --argjson load_time "$LOAD_TIME" \
        --argjson total_size "$data_size" \
        '$template[0] + {
            version: (if $version == "" then ($template[0].version // null) else $version end),
            os: $os, date: $date, machine: $machine,
            dataset_size: $dataset_size, num_loaded_documents: $num_loaded_documents,
            load_time: $load_time, total_size: $total_size,
            result: .}' > result.json

    echo "=== JSONBench result ==="
    cat result.json
    echo "=== end of JSONBench result ==="
}

bench_start_quiet() {
    ./start >/dev/null 2>&1 || true
    bench_check_loop
}

bench_stop_quiet() {
    ./stop >/dev/null 2>&1 || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    bench_main
fi
