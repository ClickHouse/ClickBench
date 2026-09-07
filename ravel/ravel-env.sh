# Shared environment for the Ravel ClickBench entry. Sourced by every script.
#
# Ravel keeps every durable byte in S3-compatible object storage; there is no
# local-disk storage mode (see README.md). The bucket is supplied by the
# operator and the credentials come from the EC2 instance profile, so no key
# ever appears in this repository or in a process argument list.
# shellcheck shell=bash

: "${RAVEL_S3_BUCKET:?set RAVEL_S3_BUCKET to a bucket the instance role may read and write}"
export RAVEL_S3_BUCKET
export RAVEL_S3_REGION="${RAVEL_S3_REGION:-us-east-1}"

# ADR-0106: fetch short-lived credentials from IMDSv2. The server refuses to
# start if an inline credential flag is set alongside this, so scrub every
# credential variable an interactive shell may have exported; a stray one would
# either fail startup or silently make the run use static keys instead of the
# instance role, which is the thing this entry is documenting.
export RAVEL_S3_AUTH=instance-role
unset RAVEL_S3_ACCESS_KEY RAVEL_S3_SECRET_KEY RAVEL_S3_SESSION_TOKEN \
      RAVEL_S3_ACCESS_KEY_ID RAVEL_S3_SECRET_ACCESS_KEY \
      AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# The AWS CLI (used only by ./data-size) reads the same instance profile.
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
# only, which is what the published numbers use.
#
# Off by default because on the ClickBench reference machine it is a
# pessimisation, measured rather than assumed. A c6a.4xlarge has no instance
# store, so "local disk" is a 500 GB gp2 volume: 286 MB/s sequential here, and
# gp2 caps at 250 MB/s sustained. The same server reads S3 at 855 MB/s
# sustained, 1,117 MB/s peak. Caching an object to this volume therefore makes
# the next read of it about 3x slower than fetching it again from S3.
#
# Set it to a path when the disk is genuinely faster than the store: an
# instance-store box (i4i, c6ad, c7gd: NVMe at multiple GB/s) or a gp3 volume
# with provisioned throughput. The disk tier is bounded by the same resolved
# ceiling as the RAM tier, 26.3 GB on this host, so the whole 11.24 GB corpus
# fits either way.
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
