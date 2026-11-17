#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: are the cold runs of chdb cold?
# Installs and loads exactly as chdb/, then measures selected cold queries.
set -e
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_RESTARTABLE=no
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh
source ../clickhouse-cold-diag/diag-common.sh
DIAG=$(pwd)
cd ../chdb

bench_install
bench_download
bench_wait_fs_init
bench_load

Q=$(pwd)/queries.sql
# shellcheck disable=SC1091
source myenv/bin/activate
echo "== diag: device $DIAG_DEV, du $(du -bs .clickbench | cut -f1)"
cat > "$DIAG/parts.sql" <<'SQL'
SELECT 'parts', version(), active, count(), sum(rows), formatReadableSize(sum(bytes_on_disk)) FROM system.parts WHERE table = 'hits' GROUP BY ALL ORDER BY ALL FORMAT TSV
SQL
python3 -c "import chdb, sys; print(chdb.session.Session('.clickbench').query(open(sys.argv[1]).read(), 'TSV'))" "$DIAG/parts.sql" | sed 's/^/diag: /'

echo "== diag: mode E: as the benchmark (flush, ./query)"
for l in $DIAG_LINES; do
    bench_flush_caches
    diag_measure E "$l" "$(diag_query_line "$l" "$Q")"
done
echo "== diag: mode P: flush, then the probe (import / open / query)"
for l in $DIAG_LINES; do
    bench_flush_caches
    diag_query_line "$l" "$Q" > "$DIAG/q.sql"
    echo "diag: P Q$((l - 1)) $(python3 "$DIAG/probe.py" "$DIAG_DEV" "$DIAG/q.sql" 2>&1 | tail -n 1)"
done
echo "== diag: mode H: hot (third ./query in a row)"
for l in $DIAG_LINES; do
    for i in 1 2; do printf '%s\n' "$(diag_query_line "$l" "$Q")" | ./query >/dev/null 2>&1 || true; done
    diag_measure H "$l" "$(diag_query_line "$l" "$Q")"
done
echo "== diag: du after $(du -bs .clickbench | cut -f1)"
python3 -c "import chdb, sys; print(chdb.session.Session('.clickbench').query(open(sys.argv[1]).read(), 'TSV'))" "$DIAG/parts.sql" | sed 's/^/diag: /'
echo "== diag: done"
