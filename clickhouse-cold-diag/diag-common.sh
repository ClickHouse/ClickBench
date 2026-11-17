#!/bin/bash
# Shared helpers of the throwaway cold-run diagnostics (not a benchmark entry).

# Query lines of queries.sql to look at: light queries with a large cold/hot
# gap in ClickHouse, plus two heavy scans for reference.
DIAG_LINES="3 5 8 11 20 21 25 27 36 41"

DIAG_DEV=$(lsblk -no pkname "$(findmnt -no source /)" 2>/dev/null)
[ -z "$DIAG_DEV" ] && DIAG_DEV=$(basename "$(findmnt -no source /)")

diag_dev_read_bytes() {
    awk -v d="$DIAG_DEV" '$3 == d { print $6 * 512 }' /proc/diskstats
}

diag_query_line() {
    sed -n "${1}p" "$2"
}

diag_mb() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1048576 }'
}

diag_s() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (b - a) / 1000000 }'
}

# Runs ./query (or the command in $DIAG_QUERY_CMD) with the query on stdin and
# prints the reported timing, the wall time of the process and the bytes read
# from the root device during it.
diag_measure() {
    local label="$1" line="$2" query="$3" raw timing b0 b1 t0 t1
    b0=$(diag_dev_read_bytes); bench_now_us; t0=$BENCH_NOW_US
    raw=$(printf '%s\n' "$query" | ${DIAG_QUERY_CMD:-./query} 2>&1 >/dev/null) || echo "diag: query failed: $(printf '%s' "$raw" | tail -n 3)"
    bench_now_us; t1=$BENCH_NOW_US; b1=$(diag_dev_read_bytes)
    timing=$(bench_extract_timing "$raw")
    echo "diag: $label Q$((line - 1)) reported=${timing:-null} wall=$(diag_s "$t0" "$t1") disk_read_MiB=$(diag_mb "$b0" "$b1")"
}
