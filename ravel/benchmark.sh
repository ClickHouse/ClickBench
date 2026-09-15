#!/bin/bash
# Ravel: object-storage-native telemetry database, queried over SQL.
#
# Ravel keeps every durable byte in S3-compatible object storage; there is no
# local-disk storage mode. For this benchmark the store is a single-node MinIO
# that ./install downloads, starts and provisions on this machine's disk, with
# credentials it generates into a file readable by the current user only, so
# nothing is required from the operator and no key is stored in this
# repository. See README.md.
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
