#!/usr/bin/env bash
# Prepare mgbench{1,2,3}.native — the Brown University benchmark log tables.
#
# Sources are header CSVs (mgbench{1,2,3}.csv.xz). We parse the timestamps with
# a modern ClickHouse (so the legacy server never has to), add a synthesised
# log_date Date (needed by the legacy MergeTree engine), and downgrade the
# types to the oldest-compatible set: LowCardinality->String, IPv4->String,
# DateTime64->DateTime. Nullable metric columns are preserved because the
# query set relies on IS NULL / IS NOT NULL (Nullable exists since 1.1.54245).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
BASE="https://clickhouse-public-datasets.s3.amazonaws.com"
run() { "${CLICKHOUSE}" local --max_memory_usage 0 --query "$1"; }

# logs1: 21 header columns of metrics; keep them Nullable(Float64).
M="Nullable(Float64)"
L1="log_time DateTime, machine_name String, machine_group String, cpu_idle $M, cpu_nice $M, cpu_system $M, cpu_user $M, cpu_wio $M, disk_free $M, disk_total $M, part_max_used $M, load_fifteen $M, load_five $M, load_one $M, mem_buffers $M, mem_cached $M, mem_free $M, mem_shared $M, swap_free $M, bytes_in $M, bytes_out $M"
echo "mgbench: logs1 -> data/mgbench1.native.zst"
run "SELECT toDate(log_time) AS log_date, * FROM url('${BASE}/mgbench1.csv.xz', 'CSVWithNames', '${L1}') FORMAT Native" | zstd -q -6 -T0 -c > "${HERE}/data/mgbench1.native.zst"
ls -l "${HERE}/data/mgbench1.native.zst"

# logs2: client_ip kept as String (no IPv4 type in old versions).
L2="log_time DateTime, client_ip String, request String, status_code UInt16, object_size UInt64"
echo "mgbench: logs2 -> data/mgbench2.native.zst"
run "SELECT toDate(log_time) AS log_date, * FROM url('${BASE}/mgbench2.csv.xz', 'CSVWithNames', '${L2}') FORMAT Native" | zstd -q -6 -T0 -c > "${HERE}/data/mgbench2.native.zst"
ls -l "${HERE}/data/mgbench2.native.zst"

# logs3: timestamp carries milliseconds; read it into a distinct String column
# (avoids an alias collision with the output log_time) and drop the fraction.
L3="log_time_raw String, device_id String, device_name String, device_type String, device_floor UInt8, event_type String, event_unit String, event_value Nullable(Float64)"
echo "mgbench: logs3 -> data/mgbench3.native.zst"
run "SELECT toDate(parseDateTimeBestEffort(log_time_raw)) AS log_date, toDateTime(parseDateTimeBestEffort(log_time_raw)) AS log_time, device_id, device_name, device_type, device_floor, event_type, event_unit, event_value FROM url('${BASE}/mgbench3.csv.xz', 'CSV', '${L3}') SETTINGS input_format_csv_skip_first_lines = 1 FORMAT Native" | zstd -q -6 -T0 -c > "${HERE}/data/mgbench3.native.zst"
ls -l "${HERE}/data/mgbench3.native.zst"
