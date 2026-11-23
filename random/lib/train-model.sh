#!/bin/bash
# Trains the model of clickhouse-obfuscator for the randomized benchmark and
# writes it into random/models/<version>/, to be committed. The machines then
# skip the training and all use the same model.
#
# Usage: train-model.sh <work dir>
#
#   RANDOM_CLICKHOUSE_VERSION  the release the model is for (the format of the
#                              model file depends on the version)
#   RANDOM_TRAIN_ROWS          the size of the sample, default 2000000
#
# The model has no seed: --save writes the parameters of the models only, and
# every group transforms the data with its own seed. The file of the
# obfuscator is compressed with ZSTD(1) in the compressed format of ClickHouse;
# the committed file is the uncompressed model, compressed with zstd -9.
# Integers in the file are native little-endian, the same on x86_64 and
# aarch64.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WORK="${1:?usage: train-model.sh <work dir>}"
: "${RANDOM_CLICKHOUSE_VERSION:?}"
: "${RANDOM_TRAIN_ROWS:=2000000}"
CH="${RANDOM_CLICKHOUSE}"
OUT="${RANDOM_DIR}/models/${RANDOM_CLICKHOUSE_VERSION}"

"${CH}" --version | grep -qF "${RANDOM_CLICKHOUSE_VERSION%-*}" \
    || { echo "${CH} is not ClickHouse ${RANDOM_CLICKHOUSE_VERSION}" >&2; exit 1; }

mkdir -p "${WORK}/source" "${WORK}/tmp" "${OUT}"
cd "${WORK}"
source "${RANDOM_DIR}/../lib/dataset-bucket.sh"
seq 0 99 | xargs -P 32 -I{} bash -c \
    "[ -s source/hits_{}.parquet ] || wget --tries=10 --continue --quiet -O source/hits_{}.parquet 'https://${DATASET_HOST}/hits_compatible/athena_partitioned/hits_{}.parquet'"

STRUCTURE="$(logical_structure)"
# A sample spread over the whole dataset, chosen by a hash of the row and in
# a fixed order, so that the training is reproducible.
per_million=$(( RANDOM_TRAIN_ROWS * 1000000 / 99997497 ))
"${CH}" local --query "
    SELECT * FROM file('source/hits_*.parquet', Parquet, \$\$${STRUCTURE}\$\$)
    WHERE cityHash64(WatchID, UserID, EventTime) % 1000000 < ${per_million}
    ORDER BY WatchID, UserID, EventTime
    FORMAT Native" > tmp/train.native
rows=$("${CH}" local --query "SELECT count() FROM file('tmp/train.native', Native)")

# The seed doesn't matter for the training; it is not saved.
start=$(date +%s)
"${CH}" obfuscator --silent 1 --seed "training" --structure "${STRUCTURE}" \
    --input-format Native --output-format Native --limit 0 --save tmp/model.bin < tmp/train.native
echo "Trained the model on ${rows} rows in $(( $(date +%s) - start )) s"

"${CH}" compressor --decompress < tmp/model.bin | zstd -9 -T0 -q -f -o "${OUT}/model.bin.zst"
cat > "${OUT}/README.md" <<EOF
The model of clickhouse-obfuscator for ClickHouse ${RANDOM_CLICKHOUSE_VERSION}, trained by
\`random/lib/train-model.sh\` on ${rows} rows of the hits dataset (a sample chosen
by \`cityHash64(WatchID, UserID, EventTime) % 1000000 < ${per_million}\`).
\`model.bin.zst\` is the uncompressed model file, compressed with \`zstd -9\`
(sha256 of the uncompressed file: $("${CH}" compressor --decompress < tmp/model.bin | sha256sum | cut -d' ' -f1)).
EOF
ls -la "${OUT}"
