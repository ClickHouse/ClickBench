#!/bin/bash
# Makes the files of the generated dataset in the format that a system loads,
# with the same names and the same physical layout as the files of the
# original dataset, so that the load scripts of the systems work unchanged.
#
# Usage: make-format.sh <work dir> <download script name> <destination dir>
#
# The download script name is BENCH_DOWNLOAD_SCRIPT of the system:
#   download-hits-parquet-partitioned  hits_<i>.parquet: nullable columns,
#                                      strings without the UTF8 annotation
#   download-hits-parquet-single       hits.parquet
#   download-hits-tsv                  hits.tsv
#   download-hits-csv                  hits.csv
# In both Parquet layouts the times are Int64 seconds and EventDate is UInt16
# days, as in the original files.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WORK="$(cd "${1:?usage: make-format.sh <work dir> <download script> <destination>}" && pwd)"
KIND="${2:?}"
DEST="${3:?}"
CH="${RANDOM_CLICKHOUSE}"
: "${RANDOM_PARALLEL:=$(nproc)}"

mkdir -p "${DEST}"
DEST="$(cd "${DEST}" && pwd)"
export TMPDIR="${WORK}/tmp"

mapfile -t parts < <(awk '{ print $1 }' "${WORK}/parts.txt")
STRUCTURE="$(cat "${WORK}/structure.txt")"

PHYSICAL="* REPLACE (
    toInt64(toUnixTimestamp(EventTime)) AS EventTime,
    toUInt16(EventDate) AS EventDate,
    toInt64(toUnixTimestamp(ClientEventTime)) AS ClientEventTime,
    toInt64(toUnixTimestamp(LocalEventTime)) AS LocalEventTime)"

export CH WORK DEST PHYSICAL STRUCTURE
# clickhouse-local reads config.xml from the current directory, and a system's
# directory may have one: run it elsewhere.
cd "${WORK}"
start=$(date +%s)
case "${KIND}" in
    download-hits-parquet-partitioned)
        # Every column is nullable in these files.
        NULLABLE="$(sed -E 's/ DateTime(,|$)/ Int64\1/g; s/ Date(,|$)/ UInt16\1/g; s/ ([A-Za-z0-9]+)(,|$)/ Nullable(\1)\2/g' <<< "${STRUCTURE}")"
        export NULLABLE
        printf '%s\n' "${parts[@]}" | xargs -P "${RANDOM_PARALLEL}" -I{} bash -c '
            "${CH}" local --max_threads 1 --input_format_parquet_preserve_order 1 \
                --engine_file_truncate_on_insert 1 --output_format_parquet_string_as_string 0 \
                --output_format_parquet_compression_method snappy --query "
                INSERT INTO FUNCTION file(\$\$${DEST}/hits_{}.parquet\$\$, Parquet, \$\$${NULLABLE}\$\$)
                SELECT ${PHYSICAL} FROM file(\$\$${WORK}/canonical/part_{}.parquet\$\$, Parquet, \$\$${STRUCTURE}\$\$)"'
        ;;
    download-hits-parquet-single)
        # One reader at a time keeps the order of the parts. The writer gets
        # the structure: without it, clickhouse-local infers the schema from
        # stdin, which it buffers whole (16 GiB on 100M rows, out of memory).
        # With several threads, the writer buffers row groups without a
        # bound when the input is faster (7 GB for 4.5M rows); with one, it
        # stays at about 1.5 GB.
        # Row groups of the size of the original file's (442K rows on
        # average), so a billion rows make about 2300 of them. The layout
        # follows the original and is not adjusted to the limits of a system:
        # a system that can't read a larger file of the same layout fails.
        SINGLE="$(sed -E 's/ DateTime(,|$)/ Int64\1/g; s/ Date(,|$)/ UInt16\1/g' <<< "${STRUCTURE}")"
        group_rows=442000
        for i in "${parts[@]}"; do
            "${CH}" local --max_threads 1 --input_format_parquet_preserve_order 1 --query "
                SELECT ${PHYSICAL} FROM file('${WORK}/canonical/part_${i}.parquet', Parquet, \$\$${STRUCTURE}\$\$) FORMAT Native"
        done | "${CH}" local --max_threads 1 --input-format Native --structure "${SINGLE}" \
            --output_format_parquet_row_group_size "${group_rows}" \
            --output_format_parquet_row_group_size_bytes 100000000000 \
            --output_format_parquet_compression_method snappy \
            --query "SELECT * FROM table INTO OUTFILE '${DEST}/hits.parquet' TRUNCATE FORMAT Parquet"
        ;;
    download-hits-tsv|download-hits-csv)
        format=TSV; ext=tsv
        [ "${KIND}" = download-hits-csv ] && { format=CSV; ext=csv; }
        export format ext
        printf '%s\n' "${parts[@]}" | xargs -P "${RANDOM_PARALLEL}" -I{} bash -c '
            "${CH}" local --max_threads 1 --input_format_parquet_preserve_order 1 --query "
                SELECT * FROM file(\$\$${WORK}/canonical/part_{}.parquet\$\$, Parquet, \$\$${STRUCTURE}\$\$)
                INTO OUTFILE \$\$${WORK}/tmp/part_{}.${ext}\$\$ TRUNCATE FORMAT ${format}"'
        : > "${DEST}/hits.${ext}"
        for i in "${parts[@]}"; do
            cat "${WORK}/tmp/part_${i}.${ext}" >> "${DEST}/hits.${ext}"
            rm -f "${WORK}/tmp/part_${i}.${ext}"
        done
        ;;
    *)
        echo "The randomized benchmark does not support ${KIND:-systems without a download script}" >&2
        exit 1
        ;;
esac
[ -n "${RANDOM_SKIP_SYNC:-}" ] || sync
echo "Made the files for ${KIND} in $(( $(date +%s) - start )) s"
