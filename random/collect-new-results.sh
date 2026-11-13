#!/bin/bash -e

# Collects the results of the randomized benchmark from the sink and
# publishes them: random/results/YYYYMMDD/<group>.json, one file per group
# (see collect-results.py). Run hourly by .github/workflows/random-collect-results.yml.
#
# The files of the groups with results in the last SINCE_HOURS hours are
# written again (the results of a group arrive over hours), committed to the
# branch auto-results/random, and a pull request with them is opened and
# merged, as json/collect-new-results.sh does for JSONBench.
#
#   SINCE_HOURS=24 random/collect-new-results.sh
#   RANDOM_GROUPS="<id> ..." random/collect-new-results.sh   # given groups
#
# DRY_RUN=1 does everything except pushing, opening and merging.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}/.."

SINCE_HOURS="${SINCE_HOURS:-24}"
[[ "${SINCE_HOURS}" =~ ^[0-9]+$ ]] || { echo "SINCE_HOURS must be a number of hours" >&2; exit 1; }
BRANCH="${BRANCH:-auto-results/random}"
DRY_RUN="${DRY_RUN:-}"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"

note() {
    echo "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$@" >> "${GITHUB_STEP_SUMMARY}"; fi
}

if [ -n "${RANDOM_GROUPS:-}" ]; then
    # shellcheck disable=SC2086
    python3 random/collect-results.py --group ${RANDOM_GROUPS}
else
    python3 random/collect-results.py --since-hours "${SINCE_HOURS}"
fi

changed=$(git status --porcelain --untracked-files=all -- random/results | awk '{ print $2 }')
if [ -z "${changed}" ]; then
    note "No new results of the randomized benchmark."
    exit 0
fi

groups=$(for f in ${changed}; do basename "${f}" .json; done | sort -u | tr '\n' ' ' | xargs)
count=$(wc -w <<<"${groups}")
if [ "${count}" -le 2 ]; then
    title="random: results of ${groups// /, }"
else
    title="random: results of ${count} groups"
fi
body="Collected from the sink by \`random/collect-new-results.sh\`.

Groups: ${groups// /, }.

The files are written by \`random/collect-results.py\` from \`sink.data\` (rows with
\`kind: random-benchmark\` and \`random-benchmark-payload\`, and the machine logs)."

if [ -n "${DRY_RUN}" ]; then
    note "DRY_RUN: would publish \"${title}\""
    git status --short -- random/results
    exit 0
fi

git add -- random/results
git -c "user.name=${BOT_NAME}" -c "user.email=${BOT_EMAIL}" commit -q -m "${title}" -m "${body}"
git push -q --force origin "HEAD:refs/heads/${BRANCH}"

url=$(gh pr list --head "${BRANCH}" --state open --json url --jq '.[0].url')
if [ -z "${url}" ]; then
    url=$(gh pr create --head "${BRANCH}" --base main --title "${title}" --body "${body}")
    note "Opened ${url}"
else
    note "Updated ${url}"
fi

for attempt in 1 2 3; do
    if gh pr merge "${url}" --merge --delete-branch; then
        note "Merged ${url}"
        exit 0
    fi
    sleep 10
done
note "Could not merge ${url}; it is left open."
