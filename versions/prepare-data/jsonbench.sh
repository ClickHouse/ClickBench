#!/usr/bin/env bash
# Prepare the JSONBench data: the Bluesky dataset (https://jsonbench.com/), as is. Unlike
# the other datasets it is not converted to Native: the documents are loaded whole into a
# JSON column (create/create.sh), and the JSON type exists only from 24.8, so there are no
# old versions to cater for. This only downloads the original files into data/bluesky/:
#   file_0001.json.gz .. file_0100.json.gz   one million documents each (~13 GB)
# JSONBENCH_FILES (default 100, the 100m size of JSONBench) sets how many.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
N="${JSONBENCH_FILES:-100}"
# The dataset is only in the eu-central-1 bucket (no us-east-1 mirror).
BASE='https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/bluesky'
mkdir -p "${HERE}/data/bluesky"
echo "jsonbench: downloading ${N} files from ${BASE} -> ${HERE}/data/bluesky"
seq --format "${BASE}/file_%04g.json.gz" 1 "${N}" \
    | xargs -P 16 -n 1 wget --quiet --continue --tries=10 --waitretry=10 --retry-connrefused --directory-prefix "${HERE}/data/bluesky"
ls "${HERE}/data/bluesky" | wc -l
