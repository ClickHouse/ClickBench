#!/bin/bash
# Eagerly download every ClickBench dataset format into the playground
# datasets dir. Run idempotent: each download script is `wget --continue`-based
# so re-running picks up where the previous run left off.
#
# Output:
#   /opt/clickbench-playground/datasets/
#     hits.parquet                       single-file Athena parquet
#     hits_partitioned/hits_0..99.parquet  partitioned parquet
#     hits.tsv                           decompressed TSV (~75 GB)
#     hits.csv                           decompressed CSV (~75 GB)
#
# These files are read-only-mounted into every Firecracker VM via a virtio-blk
# device built by `build-datasets-image.sh`.

set -e

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
DATASETS="${STATE_DIR}/datasets"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd)/lib"

mkdir -p "$DATASETS"
mkdir -p "$DATASETS/hits_partitioned"

step() { echo "[$(date -u +%FT%TZ)] $*"; }

step "parquet (single)"
if [ ! -f "$DATASETS/hits.parquet" ] || [ "$(stat -c%s "$DATASETS/hits.parquet" 2>/dev/null || echo 0)" -lt 14000000000 ]; then
    "$LIB/download-hits-parquet-single" "$DATASETS"
else
    step "  cached"
fi

step "parquet (partitioned)"
need=0
for i in $(seq 0 99); do
    f="$DATASETS/hits_partitioned/hits_${i}.parquet"
    if [ ! -f "$f" ] || [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -lt 100000000 ]; then
        need=1
        break
    fi
done
if [ "$need" = "1" ]; then
    "$LIB/download-hits-parquet-partitioned" "$DATASETS/hits_partitioned"
else
    step "  cached"
fi

step "tsv"
if [ ! -f "$DATASETS/hits.tsv" ] || [ "$(stat -c%s "$DATASETS/hits.tsv" 2>/dev/null || echo 0)" -lt 70000000000 ]; then
    "$LIB/download-hits-tsv" "$DATASETS"
else
    step "  cached"
fi

step "csv"
if [ ! -f "$DATASETS/hits.csv" ] || [ "$(stat -c%s "$DATASETS/hits.csv" 2>/dev/null || echo 0)" -lt 70000000000 ]; then
    "$LIB/download-hits-csv" "$DATASETS"
else
    step "  cached"
fi

step "done"
du -sh "$DATASETS"/*
