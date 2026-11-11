# Shared environment for the TimeFusion server and the local SeaweedFS S3 store.
# Sourced by ./start and other scripts.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TF_BIN="$DIR/timefusion/target/release/timefusion"
export WEED_BIN="$DIR/weed"
export WEED_DIR="$DIR/seaweedfs-data"

export TF_PORT=${TF_PORT:-5432}
export PGPASSWORD=postgres

# Object storage: SeaweedFS on localhost.
export AWS_ACCESS_KEY_ID=clickbench
export AWS_SECRET_ACCESS_KEY=clickbench
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export AWS_S3_BUCKET=timefusion
export AWS_S3_ENDPOINT=http://127.0.0.1:8333
export AWS_ENDPOINT_URL=http://127.0.0.1:8333
export AWS_ALLOW_HTTP=true

export PGWIRE_PORT=$TF_PORT
export PGWIRE_USER=postgres
export PGWIRE_PASSWORD=postgres
export TIMEFUSION_DATA_DIR="$DIR/timefusion-data"
# The default cap of 90 seconds per statement is too low for some ClickBench queries.
export TIMEFUSION_PGWIRE_MAX_STATEMENT_SECS=3600
export TIMEFUSION_PGWIRE_BATCH_STATEMENT_SECS=3600

# No OpenTelemetry collector here; do not export traces, logs, or metrics.
export OTEL_TRACES_EXPORTER=none
export OTEL_LOGS_EXPORTER=none
export OTEL_METRICS_EXPORTER=none
