#!/bin/bash
# Launches a group of the randomized benchmark: new random queries and a new
# random dataset, the same for every system and machine of the group.
#
#   SYSTEMS="clickhouse duckdb-parquet-partitioned ..." MACHINES="c6a.4xlarge c8g.4xlarge" random/launch.sh
#
# Environment:
#   SYSTEMS, MACHINES          what to run: every system on every machine
#   RANDOM_ROWS                the size of the dataset, default 1000000000
#   RANDOM_QUERIES             the number of queries, default 100
#   RANDOM_CANDIDATES          the number of candidates to generate, default 3x
#   RANDOM_PARALLEL_QUERIES    concurrent workers on a machine, default 4
#   RANDOM_REPEATS             runs of every query, default 3
#   RANDOM_QUERY_TIMEOUT       seconds per query, default 600
#   CLICKHOUSE_VERSION         the ClickHouse release that generates the data
#                              and the reference (default: the latest stable)
#   RANDOM_LLM_BACKEND, RANDOM_LLM_MODEL, ANTHROPIC_API_KEY, OPENAI_API_KEY
#                              see llm.py
#   repo, branch               what the machines clone (default ClickHouse/ClickBench, main)
#   OUT                        where to keep the group's files (default random/groups/<group>)
#   DRY_RUN=1                  generate and translate, but don't store the
#                              payloads in the sink and don't launch machines
#   RANDOM_SINK                the sink (default https://play.clickhouse.com/?user=sink)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HERE}/lib/common.sh"
cd "${HERE}"

: "${SYSTEMS:?SYSTEMS is required}"
: "${MACHINES:=c6a.4xlarge}"
: "${RANDOM_ROWS:=1000000000}"
: "${RANDOM_QUERIES:=100}"
: "${RANDOM_CANDIDATES:=$(( RANDOM_QUERIES * 3 ))}"
: "${RANDOM_PARALLEL_QUERIES:=4}"
: "${RANDOM_REPEATS:=3}"
: "${RANDOM_QUERY_TIMEOUT:=600}"
: "${RANDOM_SINK:=https://play.clickhouse.com/?user=sink}"
repo="${repo:-ClickHouse/ClickBench}"
branch="${branch:-main}"

note() {
    echo "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$@" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# Only the systems that load one of the generated formats can take part.
for s in ${SYSTEMS}; do
    [ -f "${CLICKBENCH_DIR}/${s}/benchmark.sh" ] || { echo "No such system: ${s}" >&2; exit 1; }
    kind=$(grep -oE 'BENCH_DOWNLOAD_SCRIPT="[^"]*"' "${CLICKBENCH_DIR}/${s}/benchmark.sh" | cut -d'"' -f2)
    # random/systems/<system>/config can set it, for a system that sets it elsewhere.
    if [ -f "${HERE}/systems/${s}/config" ] && grep -q '^BENCH_DOWNLOAD_SCRIPT=' "${HERE}/systems/${s}/config"; then
        kind=$(grep '^BENCH_DOWNLOAD_SCRIPT=' "${HERE}/systems/${s}/config" | tail -1 | cut -d= -f2 | tr -d '"')
    fi
    case "${kind}" in
        download-hits-parquet-partitioned|download-hits-parquet-single|download-hits-tsv|download-hits-csv) ;;
        *) echo "${s} loads '${kind}', which the randomized benchmark does not generate" >&2; exit 1 ;;
    esac
done

group="$(python3 -c 'import uuid; print(uuid.uuid4())')"
seed="${RANDOM_SEED:-$(python3 -c 'import secrets; print(secrets.token_hex(16))')}"
# The version with the newest committed model of the obfuscator, so that no
# machine has to train one (see lib/train-model.sh); else the latest release.
if [ -z "${CLICKHOUSE_VERSION:-}" ] && [ -d "${HERE}/models" ]; then
    CLICKHOUSE_VERSION=$(ls "${HERE}/models" | sort -V | tail -n1)
fi
if [ -z "${CLICKHOUSE_VERSION:-}" ]; then
    CLICKHOUSE_VERSION=$(curl -sSf https://api.github.com/repos/ClickHouse/ClickHouse/releases/latest | jq -r .tag_name)
    CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION#v}"
fi
OUT="${OUT:-${HERE}/groups/${group}}"
mkdir -p "${OUT}/translated" "${OUT}/payload"
export RANDOM_CLICKHOUSE="${RANDOM_CLICKHOUSE:-${OUT}/clickhouse}"
install_random_clickhouse "${CLICKHOUSE_VERSION}"

note "Randomized benchmark group ${group}"
note "Seed ${seed}, ${RANDOM_ROWS} rows, ${RANDOM_QUERIES} queries, ClickHouse ${CLICKHOUSE_VERSION}"

# A small dataset of the same kind, for the validation of the queries: four
# source files of 250 thousand rows, replicated to 2 million rows, as the full
# dataset replicates its source.
RANDOM_SEED="${seed}" RANDOM_CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION}" \
    RANDOM_ROWS=2000000 RANDOM_SOURCE_FILES="0 33 66 99" RANDOM_SOURCE_ROWS=250000 \
    RANDOM_TRAIN_ROWS=500000 "${HERE}/lib/generate-data.sh" "${OUT}/sample"
python3 "${HERE}/lib/reference.py" load "${OUT}/sample" "${OUT}/sample-db"

per_batch=30
batches=$(( (RANDOM_CANDIDATES + per_batch - 1) / per_batch ))
python3 "${HERE}/generate-queries.py" --seed "${seed}" --sample-db "${OUT}/sample-db" \
    --output "${OUT}/queries.json" --count "${RANDOM_QUERIES}" --batches "${batches}" --per-batch "${per_batch}" \
    2> >(tee "${OUT}/generate.log" >&2)

# Four systems at a time (each sends up to 8 requests at once): more runs into
# the rate limits of the API, and a batch that fails all its attempts makes
# its queries unsupported for that system.
export OUT
printf '%s\n' ${SYSTEMS} | xargs -P 4 -I{} python3 "${HERE}/translate-queries.py" "${OUT}/queries.json" {} "${OUT}/translated/{}.json"
for s in ${SYSTEMS}; do
    [ -s "${OUT}/translated/${s}.json" ] || { echo "No translation for ${s}" >&2; exit 1; }
done

for s in ${SYSTEMS}; do
    python3 "${HERE}/lib/payload.py" make "${group}" "${s}" "${OUT}/queries.json" "${OUT}/translated/${s}.json" \
        "${OUT}/payload/${s}.json" > "${OUT}/payload/${s}.sha256"
done

if [ -n "${DRY_RUN:-}" ]; then
    note "Dry run: the queries and translations are in ${OUT}"
    exit 0
fi

for s in ${SYSTEMS}; do
    curl -sSf --max-time 300 "${RANDOM_SINK}&query=INSERT+INTO+data+FORMAT+RawBLOB" --data-binary @"${OUT}/payload/${s}.json"
done

failed=""
for m in ${MACHINES}; do
    for s in ${SYSTEMS}; do
        machine="$m" system="$s" group="${group}" seed="${seed}" rows="${RANDOM_ROWS}" \
        clickhouse_version="${CLICKHOUSE_VERSION}" parallel="${RANDOM_PARALLEL_QUERIES}" \
        repeats="${RANDOM_REPEATS}" query_timeout="${RANDOM_QUERY_TIMEOUT}" \
        payload_hash="$(cat "${OUT}/payload/${s}.sha256")" repo="${repo}" branch="${branch}" \
            "${HERE}/run-benchmark.sh" || failed="${failed} ${s}/${m}"
    done
done
note "Launched; collect with: random/report.py ${group}"
if [ -n "${failed}" ]; then
    echo "Failed to launch:${failed}" >&2
    exit 1
fi
