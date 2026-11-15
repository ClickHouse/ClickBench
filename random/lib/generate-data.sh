#!/bin/bash
# Generates the randomized dataset: the original hits dataset, transformed by
# clickhouse-obfuscator with a random seed and replicated to the requested
# number of rows.
#
# Usage: generate-data.sh <work dir>
#
#   RANDOM_SEED          the seed (a string); the same seed, ClickHouse version
#                        and parameters give the same data on every machine
#   RANDOM_ROWS          the number of rows, default 1000000000
#   RANDOM_SOURCE_FILES  which of the 100 files of the original partitioned
#                        dataset (1M rows each) to start from, default all
#   RANDOM_SOURCE_ROWS   the number of rows to take from every source file,
#                        default all (1M); fewer make a small dataset that is
#                        replicated as the full one is
#   RANDOM_CLICKHOUSE_VERSION  the pinned release; the committed model in
#                        random/models/<version>/ is used if there is one
#   RANDOM_TRAIN_ROWS    the size of the sample to train the model on, when
#                        there is no committed model, default 2000000
#   RANDOM_PARALLEL      the number of generators at once, default: by the
#                        number of CPUs and the memory
#
# The result is <work dir>/canonical/part_<i>.parquet, one file for every
# source file, with the types of clickhouse/create.sql. The files of the
# formats the systems load are made from it by make-format.sh.
#
# Every source file is transformed by its own obfuscator process, with the
# same model and the same seed. The obfuscator transforms the values of a
# column with a key derived from the seed and the column name, so a UserID
# becomes the same value in every file and the data stays consistent. To make
# more rows than there are in the source, the obfuscator runs over its input
# again with a changed seed (deterministically), the same way in every file.
# So a dataset larger than the source consists of copies of the source with
# all values transformed differently: aggregates per group come in ties
# between the copies, and the queries have to break the ties.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WORK="${1:?usage: generate-data.sh <work dir>}"
: "${RANDOM_SEED:?RANDOM_SEED is required}"
: "${RANDOM_ROWS:=1000000000}"
: "${RANDOM_SOURCE_FILES:=$(seq -s ' ' 0 99)}"
: "${RANDOM_TRAIN_ROWS:=2000000}"
: "${RANDOM_SOURCE_ROWS:=}"
SOURCE_LIMIT=""
[ -n "${RANDOM_SOURCE_ROWS}" ] && SOURCE_LIMIT="LIMIT ${RANDOM_SOURCE_ROWS}"
CH="${RANDOM_CLICKHOUSE}"

mkdir -p "${WORK}/source" "${WORK}/canonical" "${WORK}/tmp"
export TMPDIR="${WORK}/tmp"
cd "${WORK}"

if [ -f canonical/done ]; then
    echo "The data is already generated"
    exit 0
fi

read -r -a files <<< "${RANDOM_SOURCE_FILES}"
nfiles=${#files[@]}

if [ -z "${RANDOM_PARALLEL:-}" ]; then
    # A generator takes about 1 GB with a model of 2M rows.
    mem_gb=$(awk '/MemAvailable/ { print int($2 / 1024 / 1024) }' /proc/meminfo)
    RANDOM_PARALLEL=$(( mem_gb / 2 ))
    [ "${RANDOM_PARALLEL}" -gt "$(nproc)" ] && RANDOM_PARALLEL=$(nproc)
    [ "${RANDOM_PARALLEL}" -lt 1 ] && RANDOM_PARALLEL=1
fi
echo "Generating ${RANDOM_ROWS} rows from ${nfiles} source files, ${RANDOM_PARALLEL} at once"

source "${RANDOM_DIR}/../lib/dataset-bucket.sh"
start=$(date +%s)
printf '%s\n' "${files[@]}" | xargs -P 32 -I{} bash -c \
    "[ -s source/hits_{}.parquet ] || wget --tries=10 --continue --quiet -O source/hits_{}.parquet 'https://${DATASET_HOST}/hits_compatible/athena_partitioned/hits_{}.parquet'"
echo "Downloaded the source in $(( $(date +%s) - start )) s"

STRUCTURE="$(logical_structure)"
printf '%s\n' "${STRUCTURE}" > structure.txt

# The model: the committed one for this version of ClickHouse (see
# train-model.sh), or trained here when there is none, or with RANDOM_TRAIN=1.
MODEL="${RANDOM_DIR}/models/${RANDOM_CLICKHOUSE_VERSION:-none}/model.bin.zst"
start=$(date +%s)
if [ -f "${MODEL}" ] && [ -z "${RANDOM_TRAIN:-}" ]; then
    # The obfuscator reads the compressed format of ClickHouse.
    zstd -d -q -c "${MODEL}" | "${CH}" compressor --codec NONE > model.bin
    echo "Using the model ${MODEL#"${RANDOM_DIR}/"}"
else
    # The sample for training: deterministic (by a hash of the row, not by the
    # reading order) and spread over the whole source.
    source_rows=$(( nfiles * 1000000 ))
    per_million=$(( RANDOM_TRAIN_ROWS * 1000000 / source_rows ))
    [ "${per_million}" -gt 1000000 ] && per_million=1000000
    "${CH}" local --query "
        SELECT * FROM file('source/hits_*.parquet', Parquet, \$\$${STRUCTURE}\$\$)
        WHERE cityHash64(WatchID, UserID, EventTime) % 1000000 < ${per_million}
        ORDER BY WatchID, UserID, EventTime
        FORMAT Native" > tmp/train.native
    "${CH}" obfuscator --silent 1 --seed "${RANDOM_SEED}" --structure "${STRUCTURE}" \
        --input-format Native --output-format Native --limit 0 --save model.bin < tmp/train.native
    rm -f tmp/train.native
    echo "Trained the model in $(( $(date +%s) - start )) s (no committed model for ClickHouse ${RANDOM_CLICKHOUSE_VERSION:-unknown})"
fi

# Rows of every part: RANDOM_ROWS spread evenly.
start=$(date +%s)
for idx in "${!files[@]}"; do
    rows=$(( RANDOM_ROWS / nfiles + (idx < RANDOM_ROWS % nfiles ? 1 : 0) ))
    echo "${idx} ${files[$idx]} ${rows}"
done > parts.txt

export CH STRUCTURE RANDOM_SEED SOURCE_LIMIT
xargs -P "${RANDOM_PARALLEL}" -L 1 bash -c '
    set -euo pipefail
    idx=$1; file=$2; rows=$3
    [ -s "canonical/part_${idx}.parquet" ] && exit 0
    # One thread keeps the order of the rows, and the result deterministic.
    "${CH}" local --max_threads 1 --input_format_parquet_preserve_order 1 --query "
        SELECT * FROM file(\$\$source/hits_${file}.parquet\$\$, Parquet, \$\$${STRUCTURE}\$\$) ${SOURCE_LIMIT} FORMAT Native" \
        > "tmp/source_${idx}.native"
    "${CH}" obfuscator --silent 1 --seed "${RANDOM_SEED}" --structure "${STRUCTURE}" \
        --input-format Native --output-format Native --load model.bin --limit "${rows}" \
        < "tmp/source_${idx}.native" \
    | "${CH}" local --max_threads 1 --input-format Native --structure "${STRUCTURE}" \
        --query "SELECT * FROM table FORMAT Parquet" > "tmp/part_${idx}.parquet"
    rm -f "tmp/source_${idx}.native"
    mv "tmp/part_${idx}.parquet" "canonical/part_${idx}.parquet"
' _ < parts.txt
echo "Generated the data in $(( $(date +%s) - start )) s"

rows=$("${CH}" local --query "SELECT count() FROM file('canonical/part_*.parquet')")
if [ "${rows}" != "${RANDOM_ROWS}" ]; then
    echo "Generated ${rows} rows instead of ${RANDOM_ROWS}" >&2
    exit 1
fi
"${CH}" --version > canonical/done
echo "Rows: ${rows}" >> canonical/done
