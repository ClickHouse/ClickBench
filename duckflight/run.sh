#!/bin/bash
# Shared implementation; each entry keeps its own working directory and state.
set -euo pipefail
entry="$1"
mode="$2"
command="$3"
shift 3
implementation="$(cd "$(dirname "$0")" && pwd)"
export DUCKFLIGHT_BENCH_ENTRY="$entry"
export DUCKFLIGHT_BENCH_STORAGE="$mode"
export DUCKFLIGHT_BENCH_STATE="${DUCKFLIGHT_BENCH_STATE:-$entry/.state}"
export PATH="$implementation/.tools:$PATH"
cd "$entry"

if [ "$mode" != native ]; then
    case "$command" in
    install|load|start|baseline|validate-native|benchmark)
        source "$entry/../lib/dataset-bucket.sh"
        export DUCKFLIGHT_BENCH_S3_REGION="${DUCKFLIGHT_BENCH_S3_REGION:-$DATASET_REGION}"
        if [ "$mode" = datalake ]; then
            export DUCKFLIGHT_BENCH_PARQUET_SOURCE="${DUCKFLIGHT_BENCH_PARQUET_SOURCE:-https://$DATASET_HOST/hits_compatible/hits.parquet}"
        else
            export DUCKFLIGHT_BENCH_PARQUET_SOURCE="${DUCKFLIGHT_BENCH_PARQUET_SOURCE:-s3://$DATASET_BUCKET/hits_compatible/athena_partitioned/hits_*.parquet}"
        fi
        ;;
    esac
fi

case "$command" in
    install) exec bash "$implementation/bootstrap.sh" ;;
    benchmark)
        export BENCH_RESTARTABLE=yes BENCH_DURABLE=yes
        export BENCH_QUERIES_FILE="$entry/queries.sql"
        if [ "$mode" = native ]; then
            export BENCH_DOWNLOAD_SCRIPT=download-hits-parquet-single
        else
            export BENCH_DOWNLOAD_SCRIPT=""
        fi
        exec "$entry/../lib/benchmark-common.sh"
        ;;
    query)
        case "${DUCKFLIGHT_BENCH_CLIENT:-rust}" in
        rust)
            IFS=: read -r host port < "$DUCKFLIGHT_BENCH_STATE/listener.csv"
            exec "$implementation/.tools/flight_sql_client" --host "$host" --port "$port" \
                --username clickbench --password="$(cat "$DUCKFLIGHT_BENCH_STATE/password")" \
                --benchmark statement-query -- "$(cat)"
            ;;
        python) ;;
        *) echo 'DUCKFLIGHT_BENCH_CLIENT must be rust or python' >&2; exit 2 ;;
        esac
        ;;
    baseline|validate-native|summarize)
        script="${command//-/_}.py"
        exec uv run --project "$implementation" --frozen --no-sync python "$implementation/$script" "$@"
        ;;
esac
exec uv run --project "$implementation" --frozen --no-sync python "$implementation/harness.py" "$command" "$@"
