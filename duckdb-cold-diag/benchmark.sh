#!/bin/bash
# Throwaway diagnostic, not a benchmark entry: are the cold runs of DuckDB
# and DuckDB (Vortex) cold? Installs and loads both exactly as duckdb/ and
# duckdb-vortex/, then measures selected cold queries.
set -e
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=no
# shellcheck source=../lib/benchmark-common.sh
source ../lib/benchmark-common.sh
source ../clickhouse-cold-diag/diag-common.sh

for s in duckdb duckdb-vortex; do
    (cd ../$s && bench_install && bench_download && bench_wait_fs_init && bench_load)
done
ls -la ../duckdb/hits.db ../duckdb-vortex/hits.vortex ../duckdb-vortex/hits.db | sed 's/^/diag: /'
echo "== diag: device $DIAG_DEV"

for s in duckdb duckdb-vortex; do
    cd ../$s
    echo "== diag: $s mode E: as the benchmark (flush, ./query)"
    for l in $DIAG_LINES; do
        bench_flush_caches
        diag_measure "$s-E" "$l" "$(diag_query_line "$l" queries.sql)"
    done
    echo "== diag: $s mode H: hot (third ./query in a row)"
    for l in $DIAG_LINES; do
        for i in 1 2; do printf '%s\n' "$(diag_query_line "$l" queries.sql)" | ./query >/dev/null 2>&1 || true; done
        diag_measure "$s-H" "$l" "$(diag_query_line "$l" queries.sql)"
    done
    cd - >/dev/null
done
echo "== diag: done"
