#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: the cold-cache cost of the mlock
# of the ClickHouse executable at startup, and ways to make it faster.
set -e
export BENCH_DOWNLOAD_SCRIPT=""
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh

bench_install
BIN=$(readlink -f /usr/bin/clickhouse)
CONF=/etc/clickhouse-server/config.d
echo "== diag: version $($BIN --version | head -1), binary $(stat -c %s "$BIN") bytes"
./stop >/dev/null 2>&1 || true

for method in plain willneed populate fadvise threads plain willneed populate fadvise threads; do
    bench_flush_caches
    sudo python3 -I mlock-test.py "$BIN" "$method" 2>&1 | sed 's/^/== diag: /'
done

bench_flush_caches
bench_now_us; a=$BENCH_NOW_US
sudo clickhouse start >/dev/null 2>&1 || true
bench_now_us; b=$BENCH_NOW_US
echo "== diag: first start (cold): sudo clickhouse start returned after $(bench_format_us $((b - a))) s"
bench_check_loop

startup() {
    echo "== diag: startup, $1:"
    local i
    for i in 1 2 3; do
        bench_startup_server_try 2>&1 | sed 's/^/    /'
    done
    sudo grep -E "mlock|Integrity check|Ready for connections" /var/log/clickhouse-server/clickhouse-server.log | tail -n 3 | cut -c 1-200 | sed 's/^/    /'
}

startup "defaults"
echo 'mlock_executable: false' | sudo tee $CONF/diag_no_mlock.yaml >/dev/null
startup "mlock_executable: false"
echo 'skip_binary_checksum_checks: true' | sudo tee $CONF/diag_skip_checksum.yaml >/dev/null
startup "mlock_executable: false, skip_binary_checksum_checks: true"
./stop >/dev/null 2>&1 || true
