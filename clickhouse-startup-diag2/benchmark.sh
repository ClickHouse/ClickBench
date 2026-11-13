#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: where the cold startup of
# ClickHouse goes once the mlock and the integrity check of the executable are
# disabled (about 2.3 s on c6a.4xlarge).
set -e
export BENCH_DOWNLOAD_SCRIPT=""
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh

bench_install
CONF=/etc/clickhouse-server/config.d
sudo tee $CONF/diag_quick.yaml >/dev/null <<'EOF'
mlock_executable: false
skip_binary_checksum_checks: true
EOF
bench_start
clickhouse-client -q "SYSTEM FLUSH LOGS"
LOG=/var/log/clickhouse-server/clickhouse-server.log
BIN=$(readlink -f /usr/bin/clickhouse)
echo "== diag: $(clickhouse-client -q 'SELECT version()'), binary $(stat -c %s "$BIN") bytes, kernel $(uname -r)"
sudo awk '$1 == "MemTotal:" || $1 == "SwapTotal:"' /proc/meminfo | sed 's/^/== diag: /'

# Sectors read from all disks and major faults in the whole system.
io_snapshot() {
    IO_SECTORS=$(awk '$3 !~ /[0-9]$/ || $3 ~ /^nvme[0-9]+n[0-9]+$/ { s += $6 } END { print s }' /proc/diskstats)
    IO_MAJFLT=$(awk '$1 == "pgmajfault" { print $2 }' /proc/vmstat)
}

# The server log of the last startup relative to t0 (microseconds since the
# epoch): the gaps of at least 20 ms, and the first and the last line.
log_timeline() {
    local t0=$1
    sudo awk '/Starting ClickHouse/ { n = 0 } { buf[n++] = $0 } END { for (i = 0; i < n; i++) print buf[i] }' "$LOG" \
    | awk -v t0="$t0" '
        BEGIN { day0 = (t0 / 1e6) % 86400 }
        function ts(line,   p) { split(substr(line, 12, 15), p, ":"); return p[1] * 3600 + p[2] * 60 + p[3] - day0 }
        $0 !~ /^[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9] / { next }
        { t = ts($0) }
        prev == "" { printf "      +%.3f first line: %s\n", t, substr($0, 28, 150) }
        prev != "" && t - prev >= 0.02 {
            printf "      +%.3f gap %.3f after: %s\n               next: %s\n", prev, t - prev, substr(prevline, 28, 170), substr($0, 28, 170)
        }
        /Ready for connections/ { printf "      +%.3f ready for connections\n", t; exit }
        { prev = t; prevline = $0 }'
}

# One startup with ./start-script $1, cold unless $2 is "warm". Prints the time
# to the first successful ./check, the disk reads and major faults during it,
# and the timeline of the server log.
try_startup() {
    local start_script=$1 mode=$2
    ./stop >/dev/null 2>&1 || true
    bench_wait_stopped
    if [ "$mode" = "warm" ]; then sync; else bench_flush_caches; fi
    io_snapshot; local s0=$IO_SECTORS f0=$IO_MAJFLT
    bench_now_us; local t0=$BENCH_NOW_US
    "$start_script" </dev/null >/dev/null 2>&1 &
    local pid=$! t1
    until ./check >/dev/null 2>&1; do sleep 0.01; done
    bench_now_us; t1=$BENCH_NOW_US
    wait "$pid" || true
    io_snapshot
    local spid
    spid=$(pgrep -o -x clickhouse-serv || true)
    echo "    $start_script $mode: ready after $(bench_format_us $((t1 - t0))) s (incl. one ./check)," \
        "read $(( (IO_SECTORS - s0) / 2048 )) MiB, $((IO_MAJFLT - f0)) major faults in the system," \
        "server: $(sudo awk '{ print "majflt " $12 ", minflt " $10 ", utime " $14 ", stime " $15 " ticks" }' /proc/"$spid"/stat 2>/dev/null)," \
        "threads $(ls /proc/"$spid"/task 2>/dev/null | wc -l)"
    LAST_T0=$t0
}

for mode in cold warm; do
    for script in ./start ./start-direct; do
        echo "== diag: $script, $mode:"
        for i in 1 2 3; do
            try_startup "$script" "$mode"
        done
        log_timeline "$LAST_T0"
    done
done

echo "== diag: cold clickhouse --version: $(bench_flush_caches; bench_now_us; a=$BENCH_NOW_US; clickhouse --version >/dev/null; bench_now_us; bench_format_us $((BENCH_NOW_US - a))) s"
echo "== diag: cold sudo true: $(bench_flush_caches; bench_now_us; a=$BENCH_NOW_US; sudo true; bench_now_us; bench_format_us $((BENCH_NOW_US - a))) s"
echo "== diag: cold clickhouse-client --version: $(bench_flush_caches; bench_now_us; a=$BENCH_NOW_US; clickhouse-client --version >/dev/null; bench_now_us; bench_format_us $((BENCH_NOW_US - a))) s"

# Where the major faults and the CPU time of a cold startup are.
if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-tools-$(uname -r)" >/dev/null 2>&1 && command -v perf >/dev/null; then
    for event in major-faults cpu-clock; do
        ./stop >/dev/null 2>&1 || true
        bench_wait_stopped
        bench_flush_caches
        if [ "$event" = major-faults ]; then opts=(-e major-faults -c 1); else opts=(-e cpu-clock -F 997); fi
        sudo perf record -q -a -g "${opts[@]}" -o /tmp/perf.data -- bash -c './start-direct >/dev/null 2>&1; until ./check >/dev/null 2>&1; do sleep 0.01; done' >/dev/null 2>&1
        spid=$(pgrep -o -x clickhouse-serv)
        echo "== diag: perf $event, cold ./start-direct, by command:"
        sudo perf report -i /tmp/perf.data --stdio --no-children --sort comm 2>/dev/null | grep -v '^#' | grep -v '^$' | grep '%' | head -12 | sed 's/^/    /'
        echo "== diag: perf $event, clickhouse-server, by symbol (self):"
        sudo perf report -i /tmp/perf.data --stdio --no-children --pid "$spid" --sort dso,symbol -g none 2>/dev/null \
            | grep -v '^#' | grep '%' | head -40 | cut -c 1-180 | sed 's/^/    /'
        echo "== diag: perf $event, clickhouse-server, by caller (children):"
        sudo perf report -i /tmp/perf.data --stdio --children --pid "$spid" --sort symbol -g none 2>/dev/null \
            | grep -v '^#' | grep '%' | head -50 | cut -c 1-180 | sed 's/^/    /'
    done
else
    echo "== diag: perf is not available"
fi
./stop >/dev/null 2>&1 || true
