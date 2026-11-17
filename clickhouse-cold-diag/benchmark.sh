#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: why are cold runs of
# ClickHouse (server) slower than chdb on light queries? Installs and loads
# exactly as clickhouse/, then runs selected queries cold in several modes.
set -e
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-partitioned"
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh
source ./diag-common.sh

bench_install
bench_start
bench_download
bench_wait_fs_init
bench_load

Q=../clickhouse/queries.sql
CH="clickhouse-client"
echo "== diag: version $($CH -q 'SELECT version()'), device $DIAG_DEV"
$CH -q "SELECT 'parts', database, table, count(), sum(rows), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE active GROUP BY ALL ORDER BY ALL FORMAT TSV"
$CH -q "SELECT 'merges after load', count() FROM system.merges FORMAT TSV"

cold_restart() {
    ./stop >/dev/null 2>&1 || true
    bench_wait_stopped
    bench_flush_caches
    local b0 b1 t0 t1
    b0=$(diag_dev_read_bytes); bench_now_us; t0=$BENCH_NOW_US
    ./start >/dev/null 2>&1 || true
    bench_check_loop
    bench_now_us; t1=$BENCH_NOW_US; b1=$(diag_dev_read_bytes)
    echo "diag:   restart: $(diag_s "$t0" "$t1") s, disk_read_MiB=$(diag_mb "$b0" "$b1")"
}

ids=()
run_server() {
    local label="$1" line="$2" query id
    query=$(diag_query_line "$line" "$Q")
    id="diag-${label}-${line}-$RANDOM"
    ids+=("$id")
    DIAG_QUERY_CMD="$CH --time --format=Pretty --query_id=$id" diag_measure "$label" "$line" "$query"
}

echo "== diag: mode A: as the benchmark (stop, flush, start, query)"
for l in $DIAG_LINES; do
    cold_restart
    $CH -q "SELECT 'diag:   merges running', count(), groupArray(result_part_name) FROM system.merges FORMAT TSV"
    run_server A "$l"
done

echo "== diag: mode B: as A, but idle 30 s after start before the query"
for l in $DIAG_LINES; do
    cold_restart
    sleep 30
    run_server B "$l"
done

echo "== diag: mode C: no restart; drop the server caches and the page cache"
for l in $DIAG_LINES; do
    for c in "MARK CACHE" "UNCOMPRESSED CACHE" "QUERY CONDITION CACHE" "PRIMARY INDEX CACHE" "SKIPPING INDEX CACHE" "MMAP CACHE" "PAGE CACHE" "QUERY CACHE"; do
        $CH -q "SYSTEM DROP $c" 2>/dev/null || true
    done
    bench_flush_caches
    run_server C "$l"
done

echo "== diag: mode W: hot (third run of the same query, server running)"
for l in $DIAG_LINES; do
    run_server W1 "$l"; run_server W2 "$l"; run_server W "$l"
done

$CH -q "SYSTEM FLUSH LOGS"
echo "== diag: query_log of all the runs"
idlist=$(printf "'%s'," "${ids[@]}"); idlist="[${idlist%,}]"
$CH -q "
SELECT query_id, query_duration_ms AS ms, read_rows,
    formatReadableSize(ProfileEvents['OSReadBytes']) AS os_read,
    formatReadableSize(ProfileEvents['ReadBufferFromFileDescriptorReadBytes']) AS fd_read,
    ProfileEvents['ReadBufferFromFileDescriptorRead'] AS fd_reads,
    round(ProfileEvents['DiskReadElapsedMicroseconds'] / 1e6, 3) AS disk_read_s,
    round(ProfileEvents['OSIOWaitMicroseconds'] / 1e6, 3) AS iowait_s,
    ProfileEvents['FileOpen'] AS opens,
    ProfileEvents['MarkCacheMisses'] AS mark_miss,
    ProfileEvents['SelectedParts'] AS parts,
    ProfileEvents['SelectedMarks'] AS marks,
    round(ProfileEvents['RealTimeMicroseconds'] / 1e6, 3) AS thread_real_s,
    round(ProfileEvents['UserTimeMicroseconds'] / 1e6, 3) AS user_s,
    ProfileEvents['OSReadChars'] AS read_chars
FROM system.query_log
WHERE type = 'QueryFinish' AND has($idlist, query_id)
ORDER BY event_time_microseconds
FORMAT PrettyCompactNoEscapes" | sed 's/^/diag: /'
echo "== diag: top ProfileEvents of the mode A runs"
$CH -q "
SELECT query_id, arrayStringConcat(arraySlice(arrayMap(x -> x.1 || '=' || toString(x.2), arrayReverseSort(x -> x.2, CAST(ProfileEvents, 'Array(Tuple(String, UInt64))'))), 1, 60), ' ')
FROM system.query_log
WHERE type = 'QueryFinish' AND has($idlist, query_id) AND query_id LIKE 'diag-A-%'
ORDER BY event_time_microseconds FORMAT TSV" | sed 's/^/diag: /'
echo "== diag: part_log event types"
$CH -q "SELECT event_type, database, table, count() FROM system.part_log GROUP BY ALL ORDER BY ALL FORMAT TSV" | sed 's/^/diag: /'

echo "== diag: mode L: server stopped; clickhouse-local over the server's data directory (like chdb)"
./stop >/dev/null 2>&1 || true
bench_wait_stopped
for l in $DIAG_LINES; do
    bench_flush_caches
    DIAG_QUERY_CMD="sudo -u clickhouse clickhouse local --path /var/lib/clickhouse/ --time --format=Pretty" diag_measure L "$l" "$(diag_query_line "$l" "$Q")"
done
echo "== diag: mode L2: clickhouse-local, second run"
for l in $DIAG_LINES; do
    DIAG_QUERY_CMD="sudo -u clickhouse clickhouse local --path /var/lib/clickhouse/ --time --format=Pretty" diag_measure L2 "$l" "$(diag_query_line "$l" "$Q")"
done
echo "== diag: done"
