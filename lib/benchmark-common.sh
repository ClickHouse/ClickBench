#!/bin/bash

# Shared ClickBench driver.
#
# A per-system benchmark.sh sets a few env vars and then exec's this script.
# This script is designed to be invoked from a system directory (e.g.
# clickhouse/), so all script paths below are relative to the system dir.
#
# Required env:
#   BENCH_DOWNLOAD_SCRIPT  Name of a top-level download-hits-* script to fetch
#                          the dataset (e.g. "download-hits-parquet-single").
#                          Set to empty string for systems that read directly
#                          from a remote source (S3 datalake, remote services).
#
# Optional env:
#   BENCH_RESTARTABLE      "yes" (default) or "no". If "yes", the system is
#                          stopped+started between every query to neutralize
#                          warm-process effects. Set "no" for in-process /
#                          single-binary tools where restart would dominate
#                          query time (duckdb CLI, sqlite, dataframe wrappers).
#   BENCH_TRIES            Number of times each query is run. Default 3.
#   BENCH_QUERIES_FILE     Path to a queries file, one query per line.
#                          Default "queries.sql" (in the system dir).
#   BENCH_CHECK_TIMEOUT    Seconds to wait for ./check to succeed. Default 300.

set -e

# Defensive HOME export: cloud-init.sh.in stamps it too, but if an
# operator's local checkout predates that fix, the install/load/query
# scripts inherit an empty HOME and tools that follow XDG conventions
# (vcpkg, duckdb extension cache, go mod cache, gizmosql installer)
# fail in confusing ways. Pin to /root so every per-system step has a
# real home directory regardless.
export HOME="${HOME:-/root}"

# BENCH_DOWNLOAD_SCRIPT must be set (possibly to empty for "no download").
: "${BENCH_DOWNLOAD_SCRIPT?BENCH_DOWNLOAD_SCRIPT is required (set empty to skip)}"
: "${BENCH_RESTARTABLE:=yes}"
: "${BENCH_TRIES:=3}"
: "${BENCH_QUERIES_FILE:=queries.sql}"
: "${BENCH_CHECK_TIMEOUT:=300}"

# Resolve the directory containing this script so we can find sibling
# helpers (download-hits-*).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

bench_flush_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

bench_install() {
    ./install
}

bench_start() {
    # Tolerate non-zero exit from ./start: many engines' start commands return
    # non-zero when the server is already up but leave the system in the
    # desired state. The check loop is the authoritative readiness signal.
    #
    # Silence ./start: many daemons (clickhouse-server, postgres, ...) print
    # progress lines to stdout/stderr that would otherwise interleave with
    # the parseable [t1,t2,t3]/Load time/Data size lines in the benchmark log.
    ./start >/dev/null 2>&1 || true
    bench_check_loop
}

bench_stop() {
    # Silence ./stop for the same reason as ./start.
    ./stop >/dev/null 2>&1
}

bench_download() {
    if [ -z "$BENCH_DOWNLOAD_SCRIPT" ]; then
        return 0
    fi
    "$LIB_DIR/$BENCH_DOWNLOAD_SCRIPT"
}

bench_load() {
    local start_t end_t
    start_t=$(date +%s.%N)
    ./load
    end_t=$(date +%s.%N)
    # Print "Load time: <secs>" matching the existing log shape that
    # play.clickhouse.com expects.
    awk -v s="$start_t" -v e="$end_t" 'BEGIN { printf "Load time: %.3f\n", e - s }'
}

# Run a single query script and emit a single JSON-array `[t1,t2,t3],` line.
# Per-try timing is also appended to result.csv as `<num>,<try>,<seconds>`.
bench_run_query() {
    local query="$1"
    local query_num="$2"
    local i raw_stderr exit_code timing
    local results=()

    bench_flush_caches
    if [ "$BENCH_RESTARTABLE" = "yes" ]; then
        ./stop >/dev/null 2>&1 || true
        ./start >/dev/null 2>&1 || true
        bench_check_loop
    fi

    for i in $(seq 1 "$BENCH_TRIES"); do
        # The query script's contract: stdout = result, stderr's last line =
        # fractional seconds, exit 0 on success.
        raw_stderr=$(printf '%s\n' "$query" | ./query 2>&1 >/dev/null) && exit_code=0 || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            # The query script's contract is "fractional seconds on the
            # last line", but several systems (pyspark, JVM-based ones,
            # anything that prints SparkSession shutdown lines after the
            # measurement) emit additional log noise after the timing,
            # so plain `tail -n1` was reading "Stopping SparkContext" or
            # similar and producing all-null result rows. Pull the LAST
            # numeric-looking line instead.
            timing=$(printf '%s\n' "$raw_stderr" | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -n1)
            [ -z "$timing" ] && timing="null"
        else
            timing="null"
            printf '%s\n' "$raw_stderr" >&2
        fi
        results+=("$timing")
        echo "${query_num},${i},${timing}" >> result.csv
    done

    # Emit "[t1,t2,t3]," for compatibility with the existing log format.
    local out="["
    local j
    for j in "${!results[@]}"; do
        out+="${results[$j]}"
        if [ "$j" -lt $((${#results[@]} - 1)) ]; then
            out+=","
        fi
    done
    out+="],"
    echo "$out"
}

bench_main() {
    bench_install
    bench_start

    bench_download
    bench_load

    : > result.csv
    local query_num=1
    while IFS= read -r query; do
        # Skip empty lines.
        [ -z "$query" ] && continue
        bench_run_query "$query" "$query_num"
        query_num=$((query_num + 1))
    done < "$BENCH_QUERIES_FILE"

    # data-size may need the server up (e.g. ClickHouse queries system.tables,
    # pandas hits the HTTP server), so report it before stopping.
    echo -n "Data size: "
    ./data-size

    bench_stop || true
}

# Only run the full flow when executed directly (or via `exec`). Sourcing the
# file (e.g. for testing individual functions) won't trigger bench_main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    bench_main
fi
