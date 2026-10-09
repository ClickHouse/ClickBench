#!/bin/bash -e

# Collect new hardware benchmark results from the sink database and publish them.
# Run hourly by .github/workflows/hardware-collect-results.yml.
#
# A machine launched by run-benchmark.sh POSTs its result as one JSON document to
# sink.data (kind = "hardware-benchmark", see cloud-init.sh.in). This script:
#
#   1. takes the latest complete result of every instance type that sent one in the
#      last SINCE_HOURS hours and writes it to results/aws_<instance type>.json,
#   2. if anything changed, commits the files to the branch auto-results/hardware,
#      opens a pull request and merges it. The page (index.html) is rebuilt from
#      the result files by the "Build the website" workflow.
#
#   CONNECTION_PARAMS='--user clickbench --password *** --host play.clickhouse.com --secure' \
#       ./collect-new-results.sh
#
# DRY_RUN=1 does everything except pushing, opening and merging.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
CH() { clickhouse-client ${CONNECTION_PARAMS} "$@"; }

SINCE_HOURS="${SINCE_HOURS:-24}"
[[ "${SINCE_HOURS}" =~ ^[0-9]+$ ]] || { echo "SINCE_HOURS must be a number of hours" >&2; exit 1; }
BRANCH="${BRANCH:-auto-results/hardware}"
DRY_RUN="${DRY_RUN:-}"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
NUM_QUERIES=$(wc -l < queries.sql)

note() {
    echo "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$@" >> "${GITHUB_STEP_SUMMARY}"; fi
}

# The latest complete result of every instance type: a result for every query, and
# at least one of them not null.
CH --query "
    SELECT argMax(content, time)
    FROM sink.data
    WHERE time >= now() - INTERVAL ${SINCE_HOURS} HOUR
      AND JSONExtractString(content, 'kind') = 'hardware-benchmark'
      AND match(JSONExtractString(content, 'instance_type'), '^[a-z0-9-]+[.][a-z0-9-]+\$')
      AND length(JSONExtractArrayRaw(content, 'result')) = ${NUM_QUERIES}
      AND arrayExists(x -> x != '[null,null,null]', JSONExtractArrayRaw(content, 'result'))
    GROUP BY JSONExtractString(content, 'instance_type')
    FORMAT TSVRaw" > /tmp/hardware-results.jsonl

# Write the files in the format of the hand-made ones: one query per line.
python3 - /tmp/hardware-results.jsonl <<'EOF'
import json, sys

for line in open(sys.argv[1]):
    if not line.strip():
        continue
    r = json.loads(line)
    out = {k: r[k] for k in ("machine", "comment", "time", "tags")}
    rows = ",\n".join("    [" + ", ".join("null" if v is None else str(v) for v in q) + "]" for q in r["result"])
    text = json.dumps(out, indent=2)[:-2] + ',\n  "result": [\n' + rows + "\n  ]\n}\n"
    json.loads(text)  # sanity check
    path = "results/aws_{}.json".format(r["instance_type"])
    with open(path, "w") as f:
        f.write(text)
    print(path, file=sys.stderr)
EOF

# --- what arrived --------------------------------------------------------------------

# Every run writes 'Instance type: <type>, total time' into its log, which is sent to
# the sink whether or not the benchmark produced a result.
started=$(CH --query "
    SELECT DISTINCT extract(content, '\nInstance type: ([a-z0-9.-]+), total time') AS t
    FROM sink.data
    WHERE time >= now() - INTERVAL ${SINCE_HOURS} HOUR AND startsWith(content, 'Hardware benchmark') AND t != ''
    ORDER BY t
    FORMAT TSV")
complete=$(python3 -c 'import json,sys; [print(json.loads(l)["instance_type"]) for l in open(sys.argv[1]) if l.strip()]' /tmp/hardware-results.jsonl)
for t in ${started}; do
    if ! grep -qxF "${t}" <<<"${complete}"; then
        note "The run on \`${t}\` did not produce a complete result."
    fi
done

machines=$(git status --porcelain -- results | awk '{print $NF}' \
    | sed 's|.*/aws_||; s|\.json$||' | sort -V | tr '\n' ' ' | xargs || true)

if [ -z "${machines}" ]; then
    note "No new hardware benchmark results in the last ${SINCE_HOURS} hours."
    exit 0
fi

# --- publish -------------------------------------------------------------------------

count=$(wc -w <<<"${machines}")
if [ "${count}" -le 5 ]; then
    title="hardware: results for ${machines// /, }"
else
    title="hardware: results for ${count} machines"
fi
body="Collected from the sink by \`hardware/collect-new-results.sh\`.

Machines: ${machines// /, }.

The result files are generated from \`sink.data\` (rows with \`kind: hardware-benchmark\`,
sent by the machines launched by \`hardware/run-benchmark.sh\`)."

note "New or updated results: ${machines// /, }."
if [ -n "${DRY_RUN}" ]; then
    note "DRY_RUN: would commit and merge \"${title}\""
    git status --short -- results
    exit 0
fi

git add -- results
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
        # The merge is pushed with GITHUB_TOKEN, which triggers no push workflows,
        # so start the website build explicitly instead of waiting for its schedule.
        gh workflow run generate-results.yml --ref main || note "Could not start the website build."
        exit 0
    fi
    sleep 10
done
note "Could not merge ${url}; it is left open."
