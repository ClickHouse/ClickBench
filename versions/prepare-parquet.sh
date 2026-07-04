#!/usr/bin/env bash
# Convert the prepared ClickHouse Native files (prepare-data/data/*.native.zst) to Parquet,
# so the other databases (DuckDB, StarRocks, CedarDB) load the SAME data as ClickHouse.
# Uses clickhouse-local, installed on the fly with the official one-liner (curl|sh), so this
# needs nothing preinstalled. Idempotent: skips files already converted.
#
#   ./prepare-parquet.sh                # convert every *.native.zst under DATA
#   ./prepare-parquet.sh hits uk        # only these basenames (native.zst stems)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${DATA:-${HERE}/prepare-data/data}"
PARQUET="${PARQUET:-${HERE}/prepare-data/parquet}"
mkdir -p "${PARQUET}"

# clickhouse-local (cached under .chlocal); the standalone binary reads native.zst and writes
# Parquet directly.
CHL_DIR="${HERE}/.chlocal"
CHL="${CHL_DIR}/clickhouse"
if [ ! -x "${CHL}" ]; then
    mkdir -p "${CHL_DIR}"
    ( cd "${CHL_DIR}" && curl -fsSL https://clickhouse.com/ | sh ) >&2
fi
[ -x "${CHL}" ] || { echo "failed to install clickhouse-local at ${CHL}" >&2; exit 1; }

# Which files: the given basenames, else everything present.
if [ "$#" -gt 0 ]; then
    files=(); for b in "$@"; do files+=("${DATA}/${b}.native.zst"); done
else
    files=("${DATA}"/*.native.zst)
fi

for f in "${files[@]}"; do
    [ -f "${f}" ] || { echo "SKIP (missing): ${f}" >&2; continue; }
    base="$(basename "${f}" .native.zst)"
    out="${PARQUET}/${base}.parquet"
    [ -f "${out}" ] && { echo "skip ${base} (parquet exists)"; continue; }
    echo "converting ${base}.native.zst -> ${base}.parquet"
    # -f reads native.zst (auto-decompressed by extension); write Parquet. tmp+mv so an
    # interrupted run never leaves a half-written parquet that a later run would skip.
    "${CHL}" local --query "SELECT * FROM file('${f}', Native) INTO OUTFILE '${out}.tmp' FORMAT Parquet" \
        && mv "${out}.tmp" "${out}" \
        || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
done
echo "parquet files in ${PARQUET}: $(ls "${PARQUET}"/*.parquet 2>/dev/null | wc -l)"
