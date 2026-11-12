#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: where does the cold startup of
# ClickHouse (about 5 s on c6a.4xlarge) go? Installs and loads exactly as
# clickhouse/, then measures cold startups under several configurations and
# prints the gaps in the server log of each.
set -e
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh

bench_install
bench_start
bench_download
bench_wait_fs_init
bench_load

LOG=/var/log/clickhouse-server/clickhouse-server.log
BIN=$(readlink -f /usr/bin/clickhouse)
CONF=/etc/clickhouse-server/config.d

echo "== diag: version $(clickhouse-client -q 'SELECT version()')"
echo "== diag: binary $BIN, $(stat -c %s "$BIN") bytes"
clickhouse-client -q "SELECT 'parts', database, count(), sum(rows), sum(bytes_on_disk) FROM system.parts WHERE active GROUP BY database ORDER BY database FORMAT TSV"
clickhouse-client -q "SELECT 'columns of hits', count() FROM system.columns WHERE table = 'hits' FORMAT TSV"
echo "== diag: files under /var/lib/clickhouse: $(sudo find /var/lib/clickhouse -type f | wc -l)"
echo "== diag: files of hits: $(sudo find /var/lib/clickhouse/store -path '*all_*' -type f | wc -l)"
echo "== diag: data disk: $(df --output=source,fstype / | tail -1)"

# Raw cold read of the binary, for comparison with the integrity check.
./stop >/dev/null 2>&1 || true
bench_wait_stopped
bench_flush_caches
bench_now_us; a=$BENCH_NOW_US
cat "$BIN" > /dev/null
bench_now_us; b=$BENCH_NOW_US
echo "== diag: cold sequential read of the binary: $(bench_format_us $((b - a))) s"
bench_flush_caches
bench_now_us; a=$BENCH_NOW_US
"$BIN" local --query 'SELECT 1' >/dev/null
bench_now_us; b=$BENCH_NOW_US
echo "== diag: cold clickhouse-local SELECT 1: $(bench_format_us $((b - a))) s"

# The lines of the last startup in the server log, from "Starting ClickHouse"
# to "Ready for connections", with the gaps of at least 50 ms between
# consecutive lines (printed as the gap and both lines).
log_gaps() {
    sudo awk '/Starting ClickHouse/ { n = 0 } { buf[n++] = $0 } END { for (i = 0; i < n; i++) print buf[i] }' "$LOG" \
    | awk '
        function ts(line,   p, t) { split(substr(line, 12, 15), p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] }
        $0 !~ /^[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9] / { next }
        { t = ts($0) }
        first == "" { first = t; print "    first log line: " substr($0, 1, 200) }
        prev != "" && t - prev >= 0.05 {
            printf "    gap %.3f s at +%.3f s\n      after: %s\n      next:  %s\n", t - prev, prev - first, substr(prevline, 28, 190), substr($0, 28, 190)
        }
        /Integrity check of the executable/ { printf "    +%.3f s: integrity check done\n", t - first }
        /Ready for connections/ { printf "    +%.3f s: ready for connections\n", t - first; exit }
        { prev = t; prevline = $0 }'
}

profile() {
    local label=$1 i
    echo "== diag: config '$label':"
    for i in 1 2 3; do
        bench_startup_server_try 2>&1 | sed 's/^/    /'
    done
    log_gaps
}

profile "as in clickhouse/ (eager loading)"

echo 'skip_binary_checksum_checks: true' | sudo tee $CONF/diag_skip_checksum.yaml >/dev/null
profile "eager loading, no binary checksum"

sudo mv $CONF/eager_load.yaml /root/eager_load.yaml
profile "defaults (async loading), no binary checksum"

sudo rm $CONF/diag_skip_checksum.yaml
profile "defaults (async loading), with binary checksum"

echo 'async_load_system_database: true' | sudo tee $CONF/diag_async_system.yaml >/dev/null
echo 'skip_binary_checksum_checks: true' | sudo tee $CONF/diag_skip_checksum.yaml >/dev/null
profile "async loading of all databases, no binary checksum"

./stop >/dev/null 2>&1 || true
