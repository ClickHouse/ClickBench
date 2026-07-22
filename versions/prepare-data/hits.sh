#!/usr/bin/env bash
# Prepare hits.native — the ClickBench "hits" dataset (100M rows, 105 columns).
#
# The published source (hits_100m_obfuscated_*.native.zst) already uses only
# types available in the oldest ClickHouse (UInt*/Int*/String/FixedString/
# Date/DateTime), so we just re-encode it to a single uncompressed Native file
# that the legacy clickhouse-client can stream straight into an INSERT.
#
# HITS_PARTS controls how many of the 256 source shards to take (0..N-1).
# Use a small number for a quick validation slice; 255 for the full 100M rows.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
OUT="${HERE}/data/hits.native.zst"
PARTS="${HITS_PARTS:-255}"

SRC="https://datasets.clickhouse.com/hits/native/hits_100m_obfuscated_{0..${PARTS}}.native.zst"
echo "hits: re-encoding shards 0..${PARTS} -> ${OUT}"
"${CLICKHOUSE}" local --max_memory_usage 0 \
    --query "SELECT * FROM url('${SRC}', 'Native') FORMAT Native" \
    | zstd -q -6 -T0 -c > "${OUT}"
ls -l "${OUT}"
