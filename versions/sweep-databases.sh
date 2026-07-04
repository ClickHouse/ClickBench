#!/usr/bin/env bash
# Full multi-engine version sweep: run every version of each engine (duckdb, starrocks,
# cedardb) over all datasets, writing <engine>/results/<version>.json. Robust: a version that
# fails or times out is logged and skipped, never stops the sweep. Resumable: a version whose
# result already exists is skipped unless FORCE=1.
#
#   ./sweep-databases.sh [engine ...]      # default: all three
#
# TRIES / QUERY_TIMEOUT come from the environment (provider defaults: 6 tries, 120s/query).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINES="${*:-duckdb starrocks cedardb}"
PER_VERSION_TIMEOUT="${PER_VERSION_TIMEOUT:-14400}"     # 4h hard cap per version
FORCE="${FORCE:-}"

for eng in ${ENGINES}; do
    tsv="${HERE}/${eng}/versions.tsv"
    [ -f "${tsv}" ] || { echo "no ${tsv}" >&2; continue; }
    mkdir -p "${HERE}/${eng}/logs" "${HERE}/${eng}/results"
    while IFS=$'\t' read -r ver rest; do
        [ -z "${ver}" ] && continue
        out="${HERE}/${eng}/results/${ver}.json"
        if [ -z "${FORCE}" ] && [ -s "${out}" ]; then
            echo "SKIP ${eng} ${ver} (result exists)"; continue
        fi
        echo "=== $(date -u +%FT%TZ) ${eng} ${ver} ==="
        timeout "${PER_VERSION_TIMEOUT}" bash "${HERE}/${eng}/run-version.sh" "${ver}" \
            > "${HERE}/${eng}/logs/sweep-${ver}.log" 2>&1 \
            && echo "  done ${eng} ${ver}" \
            || echo "  ${eng} ${ver} exited $? (see logs/sweep-${ver}.log)"
    done < "${tsv}"
done
echo "SWEEP_DONE $(date -u +%FT%TZ)"
