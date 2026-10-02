#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

BUCKETS="${KUDU_LOAD_BUCKETS:-10}"
LOG_DIR="${KUDU_LOAD_LOG_DIR:-load-logs}"
mkdir -p "$LOG_DIR"

if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
else
    DOCKER=(sudo docker)
fi

if ! [[ "$BUCKETS" =~ ^[1-9][0-9]*$ ]]; then
    echo "KUDU_LOAD_BUCKETS must be a positive integer" >&2
    exit 2
fi

run_sql_file() {
    local path="$1"
    "${DOCKER[@]}" cp "$path" "impala-client:/tmp/$(basename "$path")"
    "${DOCKER[@]}" exec -i impala-client impala-shell \
        -i impalad-1:21050 -B --quiet -f "/tmp/$(basename "$path")" < /dev/null
}

query_scalar() {
    local sql="$1"
    "${DOCKER[@]}" exec -i impala-client impala-shell \
        -i impalad-1:21050 -d clickbench -B --quiet -q "$sql" < /dev/null
}

# Clean both catalog metadata and any physical Kudu table left behind by a
# failed HMS registration. The latter is possible because Kudu CREATE and HMS
# registration are separate operations.
query_scalar 'DROP VIEW IF EXISTS hits_kudu;' >/dev/null 2>&1 || true
query_scalar 'DROP TABLE IF EXISTS hits_kudu;' >/dev/null 2>&1 || true
query_scalar 'DROP TABLE IF EXISTS hits_kudu_raw;' >/dev/null 2>&1 || true
"${DOCKER[@]}" exec kudu-master kudu table delete kudu-master:7051 \
    impala::clickbench.hits_kudu_raw \
    -nomodify_external_catalogs -reserve_seconds=0 >/dev/null 2>&1 || true

# Retain the allocated-byte baseline after logical cleanup and before creating
# the measured table. A final-run bundle can therefore show whether it began
# from a newly initialized stack or from storage carrying prior table data.
read -r master_bytes _ < <("${DOCKER[@]}" exec kudu-master du -s -B1 /var/lib/kudu/master)
read -r tserver_bytes _ < <("${DOCKER[@]}" exec kudu-tserver du -s -B1 /var/lib/kudu/tserver)
read -r hms_bytes _ < <("${DOCKER[@]}" exec impala-hms du -s -B1 /var/lib/hive/metastore)
printf 'path\tallocated_bytes\nmaster\t%s\ntserver\t%s\nhms\t%s\ntotal\t%s\n' \
    "$master_bytes" "$tserver_bytes" "$hms_bytes" \
    "$((master_bytes + tserver_bytes + hms_bytes))" \
    | tee "$LOG_DIR/pre-load-storage.tsv"

run_sql_file create_kudu.sql

SOURCE_ROWS="$(query_scalar 'SELECT COUNT(*) FROM hits;')"
template="$(< upsert_batch_template.sql)"

for ((bucket = 0; bucket < BUCKETS; bucket++)); do
    sql="${template//__BUCKETS__/$BUCKETS}"
    sql="${sql//__BUCKET__/$bucket}"
    if [[ -z "${sql//[[:space:]]/}" ]]; then
        echo "bucket=$bucket: rendered SQL is empty, refusing to run" >&2
        exit 1
    fi
    log="$LOG_DIR/bucket-$(printf '%02d' "$bucket").log"
    # -f (file mode) is required here, not piped stdin with no -f/-q. Without
    # one of those two flags, impala-shell enters its interactive cmd.Cmd
    # REPL loop instead of execute_queries_non_interactive_mode(). The REPL
    # prints query errors (e.g. OOM) to stderr but always exits 0 on EOF, so
    # a failed UPSERT batch was previously swallowed silently and the exit
    # code was never actually checked. -f restores the exit-code propagation
    # that run_sql_file()/query_scalar() above already rely on, and
    # set -euo pipefail (top of this script) then aborts the whole load.
    sql_file="$(mktemp)"
    printf '%s\n' "$sql" > "$sql_file"
    chmod 0644 "$sql_file"
    {
        echo "bucket=$bucket start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        "${DOCKER[@]}" cp "$sql_file" "impala-client:/tmp/$(basename "$sql_file")"
        "${DOCKER[@]}" exec -i impala-client impala-shell \
            -i impalad-1:21050 -B --quiet \
            -f "/tmp/$(basename "$sql_file")" < /dev/null
        echo "bucket=$bucket end=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } 2>&1 | tee "$log"
    "${DOCKER[@]}" exec -u 0 impala-client rm -f "/tmp/$(basename "$sql_file")" \
        || { echo "warning: failed to remove container tmp file for bucket=$bucket" | tee -a "$log" >&2 || true; }
    rm -f "$sql_file"
done

TARGET_ROWS="$(query_scalar 'SELECT COUNT(*) FROM hits_kudu_raw;')"
if [[ "$TARGET_ROWS" != "$SOURCE_ROWS" ]]; then
    echo "row count mismatch: source=$SOURCE_ROWS target=$TARGET_ROWS" >&2
    exit 1
fi

query_scalar 'COMPUTE STATS hits_kudu_raw;'
printf 'SOURCE_ROWS=%s\nTARGET_ROWS=%s\n' "$SOURCE_ROWS" "$TARGET_ROWS" | tee "$LOG_DIR/row-counts.log"
