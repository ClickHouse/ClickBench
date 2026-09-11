# Shared environment for the Ravel ClickBench entry. Sourced by every script.
#
# Ravel keeps every durable byte in S3-compatible object storage; there is no
# local-disk storage mode (see README.md). For this benchmark the store is a
# single-node MinIO that ./install downloads, starts and provisions on this
# machine's own disk, so the entry needs no cloud bucket and no credentials
# from the operator. To run against another S3-compatible store instead, set
# RAVEL_S3_ENDPOINT, RAVEL_S3_BUCKET, RAVEL_S3_ACCESS_KEY and
# RAVEL_S3_SECRET_KEY before ./install.
# shellcheck shell=bash

export RAVEL_S3_ENDPOINT="${RAVEL_S3_ENDPOINT:-http://127.0.0.1:9000}"
export RAVEL_S3_BUCKET="${RAVEL_S3_BUCKET:-clickbench}"
export RAVEL_S3_REGION="${RAVEL_S3_REGION:-us-east-1}"

# Where ./install keeps MinIO: its binary, its data directory (this entry's
# "data on local disk"), its pid file, its log and the credentials it
# generated. ./minio-start brings it up from here.
export MINIO_DIR="${MINIO_DIR:-$PWD/minio}"

# Static keys. ./install generates them once into a file readable by this
# user only, and every script reads them from there, so no key appears in a
# process argument list. The server and the CLI take RAVEL_S3_ACCESS_KEY and
# RAVEL_S3_SECRET_KEY; the AWS CLI (bucket provisioning and ./data-size) takes
# its own names plus the endpoint.
export RAVEL_S3_AUTH=static
if [ -z "${RAVEL_S3_ACCESS_KEY:-}" ] && [ -f "$MINIO_DIR/credentials.env" ]; then
    # shellcheck disable=SC1091
    . "$MINIO_DIR/credentials.env"
    export RAVEL_S3_ACCESS_KEY="$MINIO_ROOT_USER"
    export RAVEL_S3_SECRET_KEY="$MINIO_ROOT_PASSWORD"
fi
# The audit-trail tokenization key ./install generated; an unkeyed server
# refuses to start without one.
if [ -z "${RAVEL_AUDIT_TOKEN_KEY:-}" ] && [ -f "$MINIO_DIR/credentials.env" ]; then
    RAVEL_AUDIT_TOKEN_KEY="$(sed -n 's/^RAVEL_AUDIT_TOKEN_KEY=//p' "$MINIO_DIR/credentials.env")"
fi
export RAVEL_AUDIT_TOKEN_KEY="${RAVEL_AUDIT_TOKEN_KEY:-}"
unset RAVEL_S3_SESSION_TOKEN AWS_SESSION_TOKEN
export AWS_ACCESS_KEY_ID="${RAVEL_S3_ACCESS_KEY:-}"
export AWS_SECRET_ACCESS_KEY="${RAVEL_S3_SECRET_KEY:-}"
export AWS_ENDPOINT_URL="$RAVEL_S3_ENDPOINT"
export AWS_DEFAULT_REGION="$RAVEL_S3_REGION"

export RAVEL_TENANT="${RAVEL_TENANT:-clickbench}"
# Must match what ./load provisioned: a server configured for a different shard
# count refuses to resolve rather than answering over a subset (ADR-0050 s5).
export RAVEL_SHARDS="${RAVEL_SHARDS:-4}"

# Where ./install puts the binaries.
RAVEL_BIN_DIR="${RAVEL_BIN_DIR:-$PWD/bin}"
export RAVEL_BIN_DIR
export RAVEL_SERVER="$RAVEL_BIN_DIR/ravel-server"
export RAVEL_CLI="$RAVEL_BIN_DIR/ravel-cli"

# ADR-0046 read cache, local-disk tier. Empty (the default) means the RAM tier
# only, which is what the stock result uses. MinIO serves a ranged GET by
# reading every 1 MiB block the range touches, so with the store on this same
# volume the tier's value is not a faster disk but byte-granular reads of the
# objects the server already fetched once; the tier survives a server restart.
# The tuned result sets it (see README.md). The tier is bounded by the same
# resolved ceiling as the RAM tier, 26.3 GB with the tuned flags on this host,
# so the whole 11.24 GB corpus fits.
export RAVEL_CACHE_DIR="${RAVEL_CACHE_DIR:-}"

# Loopback only: --dev-insecure-tenant-header refuses to enable unless
# --listen-http binds a loopback address, so this stays a single-node local
# benchmark and does not weaken the server's auth posture on any reachable
# interface.
export RAVEL_HTTP="${RAVEL_HTTP:-127.0.0.1:9080}"

# ./start records the server's pid here and ./stop reads it. Stopping by pid
# rather than by command-line pattern keeps ./stop from matching, and killing,
# an unrelated process whose argv merely contains the server's flags.
export RAVEL_PIDFILE="${RAVEL_PIDFILE:-$PWD/server.pid}"
