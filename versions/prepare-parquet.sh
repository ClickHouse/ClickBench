#!/usr/bin/env bash
# Convert the prepared ClickHouse Native files (prepare-data/data/*.native.zst) to Parquet,
# so the other databases (DuckDB, StarRocks, CedarDB) load the SAME data as ClickHouse.
# Uses clickhouse-local, installed on the fly with the official one-liner (curl|sh), so this
# needs nothing preinstalled. Idempotent: skips files already converted.
#
#   ./prepare-parquet.sh                # convert every *.native.zst under DATA
#   ./prepare-parquet.sh hits uk        # only these basenames (native.zst stems)
#
# NULLABLE=1 writes a variant with every column wrapped in Nullable and snappy compression
# (default dir prepare-data/parquet-nullable). This is only for DuckDB 0.1.x, whose Parquet
# reader rejects REQUIRED fields and non-snappy codecs; every other system reads the normal
# files. Example: NULLABLE=1 ./prepare-parquet.sh uk_price_paid
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${DATA:-${HERE}/prepare-data/data}"
NULLABLE="${NULLABLE:-}"
if [ -n "${NULLABLE}" ]; then
    PARQUET="${PARQUET:-${HERE}/prepare-data/parquet-nullable}"
else
    PARQUET="${PARQUET:-${HERE}/prepare-data/parquet}"
fi
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
    echo "converting ${base}.native.zst -> ${base}.parquet${NULLABLE:+ (nullable+snappy)}"
    # tmp+mv so an interrupted run never leaves a half-written parquet that a later run skips.
    if [ -n "${NULLABLE}" ]; then
        # Wrap every column in Nullable (-> OPTIONAL fields) via a schema override on file(),
        # and force snappy -- the two things DuckDB 0.1.x's Parquet reader requires.
        schema="$("${CHL}" local --query "DESCRIBE TABLE file('${f}', Native) FORMAT TSV" \
            | awk -F'\t' '{t=$2; gsub(/^Nullable\(/,"",t); sub(/\)$/,"",t); printf "%s`%s` Nullable(%s)", (NR>1?", ":""), $1, t}')"
        "${CHL}" local --query "SELECT * FROM file('${f}', Native, '${schema}') INTO OUTFILE '${out}.tmp' FORMAT Parquet SETTINGS output_format_parquet_compression_method='snappy'" \
            && mv "${out}.tmp" "${out}" \
            || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
    else
        "${CHL}" local --query "SELECT * FROM file('${f}', Native) INTO OUTFILE '${out}.tmp' FORMAT Parquet" \
            && mv "${out}.tmp" "${out}" \
            || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
    fi
done
echo "parquet files in ${PARQUET}: $(ls "${PARQUET}"/*.parquet 2>/dev/null | wc -l)"
