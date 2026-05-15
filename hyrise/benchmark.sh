#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
#
# Hyrise has no on-disk persistence: every restart resurfaces with an empty
# catalog and the dataset must be re-loaded into RAM. BENCH_DURABLE=no makes
# the driver re-run ./load on every cold cycle (and roll that wall-clock into
# the cold-try timing) so each "cold" number genuinely measures
# load+query against a fresh in-memory dataset.
export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"
export BENCH_DURABLE=no
exec ../lib/benchmark-common.sh
