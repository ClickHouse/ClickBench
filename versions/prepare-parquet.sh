#!/usr/bin/env bash
# Convert the prepared ClickHouse Native files (prepare-data/data/*.native.zst) to Parquet,
# so the other databases (DuckDB, StarRocks, CedarDB) load the SAME data as ClickHouse.
# Uses clickhouse-local, installed on the fly with the official one-liner (curl|sh), so this
# needs nothing preinstalled. Idempotent: skips files already converted.
#
#   ./prepare-parquet.sh                # convert every *.native.zst under DATA
#   ./prepare-parquet.sh hits uk        # only these basenames (native.zst stems)
#
# Two variant modes (only one at a time), each writing to its own dir; every other system
# reads the normal files:
#   NULLABLE=1  every column Nullable + snappy (prepare-data/parquet-nullable) -- for DuckDB
#               0.1.x, whose reader rejects REQUIRED fields and non-snappy codecs.
#   CEDAR=1     FixedString(N)->String and UInt*->signed Int (prepare-data/parquet-cedar) --
#               for CedarDB, whose Parquet reader rejects char(N) and whose unsigned-int
#               aggregation overflows (round(avg(uint4))).
# Example: CEDAR=1 ./prepare-parquet.sh uk_price_paid
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${DATA:-${HERE}/prepare-data/data}"
NULLABLE="${NULLABLE:-}"
CEDAR="${CEDAR:-}"
if [ -n "${NULLABLE}" ]; then
    PARQUET="${PARQUET:-${HERE}/prepare-data/parquet-nullable}"
elif [ -n "${CEDAR}" ]; then
    PARQUET="${PARQUET:-${HERE}/prepare-data/parquet-cedar}"
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
    echo "converting ${base}.native.zst -> ${base}.parquet${NULLABLE:+ (nullable+snappy)}${CEDAR:+ (cedar-typed)}"
    # tmp+mv so an interrupted run never leaves a half-written parquet that a later run skips.
    if [ -n "${NULLABLE}" ]; then
        # Wrap every column in Nullable (-> OPTIONAL fields) via a schema override on file(),
        # and force snappy -- the two things DuckDB 0.1.x's Parquet reader requires.
        schema="$("${CHL}" local --query "DESCRIBE TABLE file('${f}', Native) FORMAT TSV" \
            | awk -F'\t' '{t=$2; gsub(/^Nullable\(/,"",t); sub(/\)$/,"",t); printf "%s`%s` Nullable(%s)", (NR>1?", ":""), $1, t}')"
        "${CHL}" local --query "SELECT * FROM file('${f}', Native, '${schema}') INTO OUTFILE '${out}.tmp' FORMAT Parquet SETTINGS output_format_parquet_compression_method='snappy'" \
            && mv "${out}.tmp" "${out}" \
            || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
    elif [ -n "${CEDAR}" ]; then
        # CedarDB: map FixedString(N)->String and unsigned ints to the next signed width (so
        # char(N) loads and round(avg(uint)) doesn't overflow), preserving Nullable. Column
        # names are lowercased because PostgreSQL folds unquoted identifiers to lower case
        # while the queries use CamelCase (e.g. ontime.Year, hits.WatchID).
        schema="$("${CHL}" local --query "DESCRIBE TABLE file('${f}', Native) FORMAT TSV" \
            | awk -F'\t' '{n=tolower($1); t=$2; nul=0;
                if (t ~ /^Nullable\(/) {nul=1; sub(/^Nullable\(/,"",t); sub(/\)$/,"",t)}
                if (t ~ /^FixedString/) t="String";
                else if (t=="UInt8") t="Int16"; else if (t=="UInt16") t="Int32";
                else if (t=="UInt32") t="Int64"; else if (t=="UInt64") t="Int64";
                if (nul) t="Nullable(" t ")";
                printf "%s`%s` %s", (NR>1?", ":""), n, t}')"
        "${CHL}" local --query "SELECT * FROM file('${f}', Native, '${schema}') INTO OUTFILE '${out}.tmp' FORMAT Parquet" \
            && mv "${out}.tmp" "${out}" \
            || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
    else
        "${CHL}" local --query "SELECT * FROM file('${f}', Native) INTO OUTFILE '${out}.tmp' FORMAT Parquet" \
            && mv "${out}.tmp" "${out}" \
            || { echo "FAILED converting ${base}" >&2; rm -f "${out}.tmp"; }
    fi
done
echo "parquet files in ${PARQUET}: $(ls "${PARQUET}"/*.parquet 2>/dev/null | wc -l)"
