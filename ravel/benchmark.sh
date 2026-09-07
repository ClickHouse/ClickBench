#!/bin/bash
# Ravel: object-storage-native telemetry database, queried over SQL.
#
# Ravel keeps every durable byte in S3-compatible object storage; there is no
# local-disk storage mode. The bucket is supplied by the operator through
# RAVEL_S3_BUCKET and the credentials come from the EC2 instance profile, so no
# key is stored in this repository. See README.md for the required permissions.
export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"

# The server is a daemon whose data survives a restart (it is in object
# storage), so the driver's defaults are right: restartable, durable, and the
# concurrent-QPS test applies.
#
# First start has to reach the object store, resolve the tenant and open the
# catalog, which is slower than a local-disk engine's start; give ./check room
# rather than failing a run on a cold control-plane round trip.
export BENCH_CHECK_TIMEOUT="${BENCH_CHECK_TIMEOUT:-600}"

exec ../lib/benchmark-common.sh
