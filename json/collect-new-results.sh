#!/bin/bash -e

# Collect new JSONBench results from the sink database and publish them.
# Run hourly by .github/workflows/json-collect-results.yml.
#
# A machine launched by run-benchmark.sh POSTs its result as one JSON document
# to sink.data (kind = "json-benchmark", see cloud-init.sh.in), together with
# the directory of the system, the dataset size, and the pull request number
# if the run was launched for a pull request. This script:
#
#   1. takes the latest complete result of every (system, dataset size,
#      machine) that arrived in the last SINCE_HOURS hours and writes it to
#      <system>/results/YYYYMMDD/<machine>_bluesky_<size>m.json, where
#      YYYYMMDD is the date of the run (older runs are kept, as in the main
#      ClickBench),
#   2. (data.generated.js is not touched: the website build, generate-results.yml,
#      regenerates it on main, so that pull requests don't conflict on it),
#   3. publishes the changes.
#
# Runs of the main branch (no PR number) are committed to the branch
# auto-results/json, and a pull request with them is opened and merged.
#
# With PR=<number>, only the runs launched for that pull request are taken
# (from any time, unless SINCE_HOURS is given), and with PUSH_PR=1 they are
# committed to the head branch of the pull request and a comment is posted.
# With PUBLISH_TO_MAIN=1 instead, they are published to main as the runs of
# main are: for the runs that finish after their pull request was merged.
# Otherwise the files are left in the working tree (e.g. for a local run).
#
#   CONNECTION_PARAMS='--user sink --host play.clickhouse.com --secure' ./collect-new-results.sh
#   PR=123 ./collect-new-results.sh
#
# DRY_RUN=1 does everything except pushing, opening, merging and commenting.

# JSON_DIR: the json/ directory of the checkout to collect into, if not this
# one: the workflow runs the script of main on a checkout of a pull request.
HERE="${JSON_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
cd "${HERE}"

: "${CONNECTION_PARAMS:=--user sink --host play.clickhouse.com --secure}"
CH() { clickhouse-client ${CONNECTION_PARAMS} "$@"; }

PR="${PR:-}"
PUSH_PR="${PUSH_PR:-}"
# With PR=<number>, publish the results to main (as the runs of main are),
# for a pull request that is already merged.
PUBLISH_TO_MAIN="${PUBLISH_TO_MAIN:-}"
if [ -n "${PR}" ]; then
    SINCE_HOURS="${SINCE_HOURS:-87600}"
else
    SINCE_HOURS="${SINCE_HOURS:-24}"
fi
[[ "${SINCE_HOURS}" =~ ^[0-9]+$ ]] || { echo "SINCE_HOURS must be a number of hours" >&2; exit 1; }
[[ "${PR}" =~ ^[0-9]*$ ]] || { echo "PR must be a number" >&2; exit 1; }
BRANCH="${BRANCH:-auto-results/json}"
DRY_RUN="${DRY_RUN:-}"
BOT_NAME="github-actions[bot]"
BOT_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

note() {
    echo "$@"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$@" >> "${GITHUB_STEP_SUMMARY}"; fi
}

if [ -n "${PR}" ]; then
    RUNS="JSONExtractString(content, 'clickbench_pr') = '${PR}'"
else
    RUNS="JSONExtractString(content, 'clickbench_pr') = ''
          AND JSONExtractString(content, 'repo') = 'ClickHouse/ClickBench'
          AND JSONExtractString(content, 'branch') = 'main'"
fi

# The latest complete result of every (system, size, machine): a result for
# every query, and at least one of them not null.
CH --query "
    SELECT argMax(content, time)
    FROM sink.data
    WHERE time >= now() - INTERVAL ${SINCE_HOURS} HOUR
      AND JSONExtractString(content, 'kind') = 'json-benchmark'
      AND match(JSONExtractString(content, 'directory'), '^[a-z0-9_-]+\$')
      AND match(JSONExtractString(content, 'machine'), '^[a-z0-9.-]+\$')
      AND JSONExtractUInt(content, 'size') IN (1, 10, 100, 1000)
      AND length(JSONExtractArrayRaw(content, 'result')) = 5
      AND arrayExists(x -> x != '[null,null,null]', JSONExtractArrayRaw(content, 'result'))
      AND ${RUNS}
    GROUP BY JSONExtractString(content, 'directory'), JSONExtractUInt(content, 'size'), JSONExtractString(content, 'machine')
    FORMAT TSVRaw" > "${TMP}/results.jsonl"

# Write the files in the format of the hand-made ones: one query per line.
python3 - "${TMP}/results.jsonl" <<'EOF'
import json, os, sys

drop = {"kind", "directory", "size", "clickbench_pr", "repo", "branch", "commit"}
for line in open(sys.argv[1]):
    if not line.strip():
        continue
    r = json.loads(line)
    directory, size, machine = r["directory"], r["size"], r["machine"]
    if not os.path.isfile(os.path.join(directory, "benchmark.sh")):
        print(f"skipping {directory}: no such system", file=sys.stderr)
        continue
    out = {k: v for k, v in r.items() if k not in drop and k != "result"}
    rows = ",\n".join("    [" + ", ".join("null" if v is None else str(v) for v in q) + "]" for q in r["result"])
    text = json.dumps(out, indent=2)[:-2] + ',\n  "result": [\n' + rows + "\n  ]\n}\n"
    json.loads(text)  # sanity check
    day = r["date"].replace("-", "")
    os.makedirs(os.path.join(directory, "results", day), exist_ok=True)
    path = os.path.join(directory, "results", day, f"{machine}_bluesky_{size}m.json")
    with open(path, "w") as f:
        f.write(text)
    print(path, file=sys.stderr)
EOF

# --- failed runs ---------------------------------------------------------------------

# The latest run of every (system, size, machine), by its log, if it failed: it exited
# with an error, or no query succeeded (e.g. every query was rejected). A failed run
# sends only its log, so the system, size and machine come from the log, and the error
# is its last line that looks like one. The page shows such systems as failed at that
# size (if they worked at a smaller one), so a failure is recorded as a result file
# with an "error" field, which a later successful run replaces.
if [ -n "${PR}" ]; then
    LOGS="m[3] = '${PR}'"
else
    LOGS="m[3] = '' AND position(content, '\nRepository: ClickHouse/ClickBench, branch: main\n') > 0"
fi
CH --query "
    SELECT dir, size, machine, toDate(t) AS day, err
    FROM
    (
        SELECT m[1] AS dir, toUInt32(m[2]) AS size,
            extract(content, '\nExit status: [0-9]+, instance type: ([a-z0-9.-]+),') AS machine,
            argMax(toUInt32OrZero(extract(content, '\nExit status: ([0-9]+)')), time) AS exit,
            argMax(match(content, '\n\\\\[[0-9][^\n]*\\\\],\n'), time) AS any_query_succeeded,
            -- The last line that starts like an error message, or else the last one
            -- that mentions an error.
            argMax(left(if(notEmpty(errors), errors[-1], if(notEmpty(mentions), mentions[-1], '')), 300), time) AS err,
            max(time) AS t
        FROM
        (
            SELECT extractGroups(content, '^JSONBench system: ([a-z0-9_-]+), size: ([0-9]+)m, PR: ([0-9]*)\n') AS m, content, time,
                arrayFilter(l -> NOT startsWith(l, 'Exit status') AND NOT startsWith(l, 'load: skipped'),
                    arrayMap(l -> trim(replaceRegexpAll(l, '\x1B\\\\[[0-9;]*m', '')), splitByChar('\n', content))) AS lines,
                arrayFilter(l -> match(l, '^(ERROR|FATAL|PANIC|Error|error|Failed|✘)'), lines) AS errors,
                arrayFilter(l -> match(l, '(?i)(error|fail|exceed|timeout|traceback|not supported|refus|denied|killed|panic)'), lines) AS mentions
            FROM sink.data
            WHERE time >= now() - INTERVAL ${SINCE_HOURS} HOUR
              AND startsWith(content, 'JSONBench system: ')
              AND position(content, '\nExit status: ') > 0
        )
        WHERE length(m) = 3 AND ${LOGS} AND machine != ''
        GROUP BY dir, size, machine
    )
    WHERE size IN (1, 10, 100, 1000) AND (exit != 0 OR NOT any_query_succeeded)
    FORMAT TSVRaw" > "${TMP}/failed.tsv"

python3 - "${TMP}/failed.tsv" <<'PY'
import json, os, sys

for line in open(sys.argv[1]):
    if not line.strip():
        continue
    directory, size, machine, day, error = line.rstrip("\n").split("\t", 4)
    template = os.path.join(directory, "template.json")
    if not os.path.isfile(template):
        print(f"skipping {directory}: no such system", file=sys.stderr)
        continue
    with open(template) as f:
        out = {k: v for k, v in json.load(f).items() if k in ("system", "proprietary", "retains_structure", "tags")}
    out.update({"date": day, "machine": machine, "dataset_size": int(size) * 1000000,
                "error": error.strip() or "the run failed"})
    path = os.path.join(directory, "results", day.replace("-", ""), f"{machine}_bluesky_{size}m.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    print(f"{path}: failed: {out['error']}", file=sys.stderr)
PY

# --- what arrived --------------------------------------------------------------------

# Every run sends its log, starting with 'JSONBench system: <dir>, size: <n>m, PR: <pr>',
# whether or not it produced a result.
started=$(CH --query "
    SELECT DISTINCT concat(m[1], '/', m[2], 'm') AS run
    FROM (SELECT extractGroups(content, '^JSONBench system: ([a-z0-9_-]+), size: ([0-9]+)m, PR: ([0-9]*)\n') AS m
          FROM sink.data
          WHERE time >= now() - INTERVAL ${SINCE_HOURS} HOUR AND startsWith(content, 'JSONBench system: '))
    WHERE length(m) = 3 AND m[3] = '${PR}'
    ORDER BY run
    FORMAT TSV")
complete=$(python3 -c 'import json,sys; [print("{}/{}m".format(r["directory"], r["size"])) for r in map(json.loads, filter(str.strip, open(sys.argv[1])))]' "${TMP}/results.jsonl" | sort -u)
for run in ${started}; do
    if ! grep -qxF "${run}" <<<"${complete}"; then
        note "The run of \`${run}\` has not produced a complete result (still running, or failed)."
    fi
done

# A result whose content did not change is left as it was (a re-serialisation
# could still differ in the formatting).
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
    fi
done < <(git diff --name-only --relative -- '*/results/*/*.json')

changed=$(git status --porcelain --untracked-files=all -- '*/results/*/*.json' | awk '{print $NF}' | sed "s|^${prefix}||" | sort | tr '\n' ' ' | xargs || true)
if [ -z "${changed}" ]; then
    note "No new JSONBench results${PR:+ of PR #${PR}} in the last ${SINCE_HOURS} hours."
    exit 0
fi
note "New or updated results: ${changed// /, }."


# --- publish -------------------------------------------------------------------------

runs=$(for f in ${changed}; do echo "${f%%/*}/$(basename "${f}" .json | sed 's/.*_bluesky_//')"; done | sort -u | tr '\n' ' ' | xargs)
count=$(wc -w <<<"${runs}")
if [ "${count}" -le 4 ]; then
    title="json: results for ${runs// /, }"
else
    title="json: results for ${count} runs"
fi
body="Collected from the sink by \`json/collect-new-results.sh\`.

Runs: ${runs// /, }.

The result files are generated from \`sink.data\` (rows with \`kind: json-benchmark\`,
sent by the machines launched by \`json/run-benchmark.sh\`)."

if [ -n "${DRY_RUN}" ]; then
    note "DRY_RUN: would publish \"${title}\""
    git status --short -- .
    exit 0
fi

if [ -n "${PR}" ] && [ -z "${PUBLISH_TO_MAIN}" ]; then
    [ -n "${PUSH_PR}" ] || exit 0
    git add -- '*/results/*/*.json'
    git -c "user.name=${BOT_NAME}" -c "user.email=${BOT_EMAIL}" commit -q -m "${title}" -m "${body}"
    git push -q origin "HEAD:refs/heads/${PR_HEAD_BRANCH:?PR_HEAD_BRANCH is required with PUSH_PR}"
    gh pr comment "${PR}" --body "${body}"
    note "Committed to PR #${PR}"
    exit 0
fi

git add -- '*/results/*/*.json'
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
        gh workflow run generate-results.yml --ref main || note "Could not start the website build."
        exit 0
    fi
    sleep 10
done
note "Could not merge ${url}; it is left open."
