#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: the cost of building the symbol index
# (`SymbolIndex::instance`), which the server does on the main thread at startup.
# clickhouse-local builds it only on demand, so `SELECT buildId()` minus `SELECT 1` is its cost.
set -e
export BENCH_DOWNLOAD_SCRIPT=""
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh

bench_install
BIN=$(readlink -f /usr/bin/clickhouse)
echo "== diag: $($BIN --version | head -1), binary $(stat -c %s "$BIN") bytes"
python3 -I sections.py "$BIN" | sed 's/^/== diag: section /'
sudo clickhouse stop >/dev/null 2>&1 || true

io_snapshot() {
    IO_SECTORS=$(awk '$3 !~ /[0-9]$/ || $3 ~ /^nvme[0-9]+n[0-9]+$/ { s += $6 } END { print s }' /proc/diskstats)
}

run() {
    local mode=$1 query=$2 a b s0
    if [ "$mode" = cold ]; then bench_flush_caches; fi
    io_snapshot; s0=$IO_SECTORS
    bench_now_us; a=$BENCH_NOW_US
    "$BIN" local --query "$query" >/dev/null
    bench_now_us; b=$BENCH_NOW_US
    io_snapshot
    echo "== diag: $mode $(printf '%-20s' "'$query'"): $(bench_format_us $((b - a))) s, read $(( (IO_SECTORS - s0) / 2048 )) MiB"
}

for mode in cold warm; do
    for i in 1 2 3; do
        run "$mode" "SELECT 1"
        run "$mode" "SELECT buildId()"
        run "$mode" "SELECT count() FROM system.symbols"
    done
done
