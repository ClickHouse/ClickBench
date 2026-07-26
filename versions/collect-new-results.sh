#!/bin/bash -e

# Collect new Versions Benchmark results from the sink database and publish them.
# Run hourly by .github/workflows/versions-collect-results.yml.
#
# Unlike the main benchmark, this one has no materialized view: a machine POSTs its
# whole result JSON to sink.data (kind = "versions-benchmark", see cloud-init.sh.in),
# so results are read straight from those rows. fetch-results.sh does that reading;
# this script is the automation around it:
#
#   1. fetch the results that arrived in the last SINCE_HOURS hours (FULL=1: refetch
#      every version and rebuild results/ from scratch),
#   2. regenerate data.generated.js,
#   3. if anything changed, commit results/ + data.generated.js to the branch
#      auto-results/versions, open a pull request and merge it (these results are
#      ClickHouse's own, so they are trusted, as the main collector trusts the
#      clickhouse* systems),
#   4. report what arrived, including runs that sent a log but no usable result.
#
#   CONNECTION_PARAMS='--user clickbench --password *** --host play.clickhouse.com --secure' \
#       ./collect-new-results.sh
#
# DRY_RUN=1 does everything except pushing, opening and merging.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
CH() { clickhouse-client ${CONNECTION_PARAMS} "$@"; }

SINCE_HOURS="${SINCE_HOURS:-24}"
FULL="${FULL:-}"
BRANCH="${BRANCH:-auto-results/versions}"
DRY_RUN="${DRY_RUN:-}"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

note() {
    echo "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$@" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# --- fetch -------------------------------------------------------------------------

before=$(ls results/*.json 2>/dev/null | wc -l)
if [ -n "${FULL}" ]; then SINCE_HOURS=""; fi
SINCE_HOURS="${SINCE_HOURS}" ./fetch-results.sh
after=$(ls results/*.json 2>/dev/null | wc -l)

# A full refresh that loses a large part of the results means the query or the sink
# went wrong, not that the results are gone: never commit such a mass deletion.
if [ -n "${FULL}" ] && [ "${after}" -lt $(( before * 9 / 10 )) ]; then
    note "Refusing to publish: the full fetch produced ${after} result files, was ${before}."
    exit 1
fi

# fetch-results.sh and apply-minvers.py re-serialise the files they touch, so a result can
# come back byte-different but identical in content: jq rewrites 0.020 as 0.02 whenever it
# has to reconstruct a document (and different jq versions differ in when they do). Left
# alone, that would make this job commit a few hundred formatting-only diffs every hour, so
# restore every file whose content did not actually change.
restored=0
prefix=$(git rev-parse --show-prefix)
while read -r f; do
    [ -z "${f}" ] && continue
    if git show "HEAD:${prefix}${f}" 2>/dev/null | python3 -c '
import json, sys
old = json.load(sys.stdin)
with open(sys.argv[1]) as fh:
    new = json.load(fh)
sys.exit(0 if old == new else 1)' "${f}"; then
        git checkout -q -- "${f}"
        restored=$((restored + 1))
    fi
done < <(git diff --name-only --relative -- results)
if [ "${restored}" != 0 ]; then
    echo "kept ${restored} result file(s) unchanged (re-serialisation only)" >&2
fi

# --- what arrived ------------------------------------------------------------------

# Every run writes '=== benchmarking <version> (image ...)' into its log, which is sent
# to the sink whether or not the benchmark produced a result. Versions with a log but no
# result file of their own are runs that are still going, crashed, or loaded incompletely
# (fetch-results.sh skips those) -- worth reporting, since nothing else would show them.
window="${SINCE_HOURS:-24}"
started=$(CH --query "
    SELECT DISTINCT extract(content, '=== benchmarking ([^ ]+) ') AS v
    FROM sink.data
    WHERE time >= now() - INTERVAL ${window} HOUR AND v != ''
    ORDER BY v
    FORMAT TSV")
# The runs that did finish, by the same criterion fetch-results.sh uses (a complete
# result array). Compared with the logs above, not with the result files: a version
# benchmarked before the window still has its file, so the files say nothing about
# whether this run of it finished.
complete=$(CH --query "
    SELECT DISTINCT JSONExtractString(content, 'version') AS v
    FROM sink.data
    WHERE JSONExtractString(content, 'kind') = 'versions-benchmark' AND v != ''
      AND length(JSONExtractArrayRaw(content, 'result')) = 344
      AND time >= now() - INTERVAL ${window} HOUR
    ORDER BY v
    FORMAT TSV")

versions=$(git status --porcelain -- results | awk '{print $NF}' \
    | sed 's|.*/||; s|\.json$||' | sort -V | tr '\n' ' ' | xargs || true)

for v in ${started}; do
    if ! grep -qxF "${v}" <<<"${complete}"; then
        note "The run of \`${v}\` has not produced a result yet (still running, failed, or an incomplete load)."
    fi
done

if [ -z "${versions}" ]; then
    note "No new versions benchmark results in the last ${window} hours."
    exit 0
fi

# The page data is derived from the result files, so it is rebuilt only when they change
# (regenerating it unconditionally would rewrite it on every run: jq reformats the numbers
# the same way it does in the result files).
./generate-results.sh

# --- publish -----------------------------------------------------------------------

count=$(wc -w <<<"${versions}")
if [ "${count}" -le 5 ]; then
    title="versions: results for ${versions// /, }"
else
    title="versions: results for ${count} versions"
fi
body="Collected from the sink by \`versions/collect-new-results.sh\`.

Versions: ${versions// /, }.

The result files are generated: they are fetched from \`sink.data\` (rows with
\`kind: versions-benchmark\`, sent by the machines the versions benchmark runs on),
and \`data.generated.js\` is rebuilt from them. Do not edit them by hand."

note "New or updated results: ${versions// /, }."
if [ -n "${DRY_RUN}" ]; then
    note "DRY_RUN: would commit and merge \"${title}\""
    git status --short -- results data.generated.js
    exit 0
fi

git add -- results data.generated.js
git -c "user.name=${BOT_NAME}" -c "user.email=${BOT_EMAIL}" commit -q -m "${title}" -m "${body}"
git push -q --force origin "HEAD:refs/heads/${BRANCH}"

url=$(gh pr list --head "${BRANCH}" --state open --json url --jq '.[0].url')
if [ -z "${url}" ]; then
    url=$(gh pr create --head "${BRANCH}" --base main --title "${title}" --body "${body}")
    note "Opened ${url}"
else
    note "Updated ${url}"
fi

# Retry: GitHub may still be computing mergeability right after the push.
for attempt in 1 2 3; do
    if gh pr merge "${url}" --merge --delete-branch; then
        note "Merged ${url}"
        exit 0
    fi
    sleep 10
done
note "Could not merge ${url}; it is left open."
