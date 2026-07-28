#!/usr/bin/env python3
"""Collect new benchmark results from the sink database and distribute them.

Every benchmark machine sends two logs to sink.data on play.clickhouse.com:
the benchmark script log and the raw cloud-init log (see cloud-init.sh.in).
Good runs are parsed into sink.results by a materialized view
(prepare-database.sql). This script looks at the runs of the last day and:

- for runs launched for a pull request (clickbench_pr != 0): commits the
  result files to the PR branch like collect-results.sh would, removes result
  files that were added to the PR manually, and posts a comment with the list
  of machines whose results are ready and pastila.nl links to both logs;
  runs that produced no results get a comment with the logs too;
- for runs of main: keeps at most one open automated pull request per system
  (head branch auto-results/<system>), adding result files and log links to
  it, or opening a new one with the links in the description; PRs for
  ClickHouse variants (system name clickhouse or clickhouse-*) are trusted
  and merged automatically right after opening;
- never posts the same run twice: every posted run leaves an HTML comment
  marker on the pull request, and result files are also compared by content.

Reads the database as the read-only `clickbench` user (password in the
CLICKBENCH_DB_PASSWORD environment variable / GitHub secret) and talks to
GitHub through `gh` (GH_TOKEN). Requires a checkout of the repository as the
working directory. Set DRY_RUN=1 to print actions instead of performing them.

The workflow's GITHUB_TOKEN cannot push to forks, so results for fork PRs
are posted as paste links — unless CLICKBENCH_FORK_PUSH_TOKEN holds a classic
PAT of a user with write access to this repository: GitHub grants the "allow
edits from maintainers" push permission to such user accounts (not to App
installation tokens like GITHUB_TOKEN), so with the token the script commits
results to fork PRs whose author left maintainer edits enabled.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time as time_module
import urllib.parse
import urllib.request

DB_URL = os.environ.get("CLICKBENCH_DB_URL") or "https://play.clickhouse.com/"
DB_USER = os.environ.get("CLICKBENCH_DB_USER") or "clickbench"
DB_PASSWORD = os.environ.get("CLICKBENCH_DB_PASSWORD") or ""
PASTILA_DB_URL = "https://uzg8q0g12h.eu-central-1.aws.clickhouse.cloud/?user=paste"
REPO = os.environ.get("GITHUB_REPOSITORY") or "ClickHouse/ClickBench"
FORK_PUSH_TOKEN = os.environ.get("CLICKBENCH_FORK_PUSH_TOKEN") or ""
DRY_RUN = bool(os.environ.get("DRY_RUN"))
BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"

SYSTEM_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}$")
MACHINE_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}$")

summary_lines = []
errors = []


def note(line):
    print(line, flush=True)
    summary_lines.append(line)


def run(*cmd, check=True, input=None):
    result = subprocess.run(cmd, capture_output=True, text=True, input=input)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def http_post(url, body, headers=None, retries=3):
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=body.encode())
            for name, value in (headers or {}).items():
                req.add_header(name, value)
            with urllib.request.urlopen(req, timeout=180) as response:
                return response.read().decode("utf-8", "replace")
        except Exception:
            if attempt == retries - 1:
                raise
            time_module.sleep(5)


def ch(sql, **params):
    """Run a query against the sink database, with server-side parameters."""
    # Parameter values are parsed in the Escaped format: control characters
    # and backslashes must be escaped, or the value is rejected.
    def escape(value):
        return str(value).replace("\\", "\\\\").replace("\n", "\\n") \
            .replace("\t", "\\t").replace("\r", "\\r")

    # The URL must carry at least one query parameter: play.clickhouse.com
    # redirects the bare / to the UI, and urllib follows the redirect as a
    # GET, losing the query and returning HTML instead of the result.
    query = {"default_format": "JSON"}
    query.update({f"param_{k}": escape(v) for k, v in params.items()})
    url = DB_URL + ("&" if "?" in DB_URL else "?") + urllib.parse.urlencode(query)
    headers = {"X-ClickHouse-User": DB_USER}
    if DB_PASSWORD:
        headers["X-ClickHouse-Key"] = DB_PASSWORD
    return http_post(url, sql, headers)


def ch_rows(sql, **params):
    return json.loads(ch(sql + " FORMAT JSON", **params))["data"]


# === pastila.nl ===
# A paste is an insert into pastila's ClickHouse instance; the URL is
# https://pastila.nl/?<fingerprint>/<hash> where hash is ClickHouse-flavored
# sipHash128 of the content and fingerprint groups revisions of similar texts.
# Both are reimplementations of the functions in ClickHouse/pastila.

def siphash128_hex(data):
    mask = (1 << 64) - 1

    def rotl(x, b):
        return ((x << b) | (x >> (64 - b))) & mask

    v = [0x736F6D6570736575, 0x646F72616E646F6D, 0x6C7967656E657261, 0x7465646279746573]

    def compress():
        v[0] = (v[0] + v[1]) & mask
        v[2] = (v[2] + v[3]) & mask
        v[1] = rotl(v[1], 13)
        v[3] = rotl(v[3], 16)
        v[1] ^= v[0]
        v[3] ^= v[2]
        v[0] = rotl(v[0], 32)
        v[2] = (v[2] + v[1]) & mask
        v[0] = (v[0] + v[3]) & mask
        v[1] = rotl(v[1], 17)
        v[3] = rotl(v[3], 21)
        v[1] ^= v[2]
        v[3] ^= v[0]
        v[2] = rotl(v[2], 32)

    n = len(data)
    offset = 0
    while offset + 8 <= n:
        word = int.from_bytes(data[offset:offset + 8], "little")
        v[3] ^= word
        compress()
        compress()
        v[0] ^= word
        offset += 8
    tail = bytearray(8)
    tail[:n - offset] = data[offset:]
    tail[7] = n & 0xFF
    word = int.from_bytes(tail, "little")
    v[3] ^= word
    compress()
    compress()
    v[0] ^= word
    v[2] ^= 0xFF
    for _ in range(4):
        compress()
    hex32 = format(((v[2] ^ v[3]) << 64) | (v[0] ^ v[1]), "032x")
    return "".join(reversed([hex32[i:i + 2] for i in range(0, 32, 2)]))


def get_fingerprint(text):
    words = re.findall(r"[^\W\d_]{4,100}", text)
    # The fingerprint only groups revisions of a paste for the history view,
    # so unlike the hash it does not have to cover the whole text: cap the
    # work to keep megabyte-sized logs fast.
    triples = [",".join(words[i:i + 3]) for i in range(min(len(words) - 2, 5000))]
    fingerprint = "ffffffff"
    for triple in dict.fromkeys(triples):
        candidate = siphash128_hex(triple.encode())[:8]
        if candidate < fingerprint:
            fingerprint = candidate
    return fingerprint


def pastila_post(text):
    if not text:
        return None
    if DRY_RUN:
        print(f"DRY_RUN: would post {len(text)} bytes to pastila.nl")
        return "https://pastila.nl/?00000000/dryrun"
    fingerprint = get_fingerprint(text)
    content_hash = siphash128_hex(text.encode())
    row = {
        "fingerprint_hex": fingerprint,
        "hash_hex": content_hash,
        "prev_fingerprint_hex": "",
        "prev_hash_hex": "",
        "content": text,
        "is_encrypted": False,
    }
    http_post(PASTILA_DB_URL, "INSERT INTO data (fingerprint_hex, hash_hex, "
              "prev_fingerprint_hex, prev_hash_hex, content, is_encrypted) "
              "FORMAT JSONEachRow " + json.dumps(row))
    return f"https://pastila.nl/?{fingerprint}/{content_hash}"


# === GitHub ===

def gh(*args, input=None):
    return run("gh", *args, input=input)


def gh_json(*args):
    return json.loads(gh(*args))


def pr_meta(number):
    result = subprocess.run(["gh", "api", f"repos/{REPO}/pulls/{number}"],
                            capture_output=True, text=True)
    return json.loads(result.stdout) if result.returncode == 0 else None


def posted_text(number, body=""):
    """Everything already posted on a PR: its description and all comments."""
    comments = gh("api", f"repos/{REPO}/issues/{number}/comments",
                  "--paginate", "--jq", ".[].body")
    return body + "\n" + comments


def post_comment(number, body):
    if DRY_RUN:
        print(f"DRY_RUN: would comment on #{number}:\n{body}\n---")
        return
    gh("api", f"repos/{REPO}/issues/{number}/comments", "-f", "body=" + body)


def merge_pr(url):
    """Merge an automated PR with a merge commit and delete its branch.
    Retries because GitHub may still be computing mergeability right after
    the PR is created."""
    if DRY_RUN:
        print(f"DRY_RUN: would merge {url}")
        return
    for attempt in range(3):
        try:
            gh("pr", "merge", url, "--merge", "--delete-branch")
            return
        except RuntimeError:
            if attempt == 2:
                raise
            time_module.sleep(5)


def marker(run_row):
    return "<!-- clickbench-collect: {system}/{machine}/{time} -->".format(**run_row)


# === sink queries ===

def fetch_runs():
    """One row per benchmark run of the last day, from the logs in sink.data,
    joined with sink.results to tell good runs from failed ones."""
    # The alias must not be named `time`: an alias shadows the column in the
    # rest of the query, breaking formatDateTime and the WHERE.
    runs = ch_rows("""
        SELECT toString(time) AS time_str,
               formatDateTime(time, '%Y%m%d', 'UTC') AS date,
               extract(content, 'System: ([^\\n]+)') AS system,
               extract(content, 'Machine: ([^\\n]+)') AS machine,
               toUInt32OrZero(extract(content, 'ClickBench PR: (\\d*)')) AS pr
        FROM sink.data
        WHERE time >= now() - INTERVAL 1 DAY
            AND content NOT LIKE 'Cloud-init%' AND content LIKE 'System name: %'
        ORDER BY time""")
    results = ch_rows("""
        SELECT toString(time) AS time_str, system, machine, output
        FROM sink.results WHERE time >= now() - INTERVAL 1 DAY""")
    for r in runs + results:
        r["time"] = r.pop("time_str")
    outputs = {(r["time"], r["system"], r["machine"]): r["output"] for r in results}
    valid = {}
    for r in runs:
        if not SYSTEM_RE.match(r["system"]) or not MACHINE_RE.match(r["machine"]):
            continue
        r["output"] = outputs.get((r["time"], r["system"], r["machine"]))
        r["good"] = r["output"] is not None
        if r["good"]:
            try:
                json.loads(r["output"])
            except ValueError:
                continue
        valid[(r["time"], r["system"], r["machine"])] = r
    return list(valid.values())


def fetch_logs(run_row):
    """The benchmark script log and the matching raw cloud-init log."""
    rows = ch_rows("""
        SELECT content FROM sink.data
        WHERE time = parseDateTimeBestEffort({t:String})
            AND content NOT LIKE 'Cloud-init%' AND content LIKE 'System name: %'
            AND position(content, {sys_mark:String}) > 0
            AND position(content, {machine_mark:String}) > 0
        LIMIT 1""",
        t=run_row["time"],
        sys_mark="\nSystem: {system}\n".format(**run_row),
        machine_mark="\nMachine: {machine}\n".format(**run_row))
    bench_log = rows[0]["content"] if rows else None

    # The cloud-init log is a separate insert seconds later. It contains the
    # whole benchmark log too (cloud-init captures stdout), so match it by a
    # line that is unique to this run: the last 'Total time: N' of the log.
    # Multi-line needles do not work: stderr traces are interleaved there.
    cloud_init_log = None
    if bench_log:
        totals = re.findall(r"Total time: \d+", bench_log)
        needle = totals[-1] if totals else "System: {system}".format(**run_row)
        rows = ch_rows("""
            SELECT content FROM sink.data
            WHERE time >= parseDateTimeBestEffort({t:String})
                AND time <= parseDateTimeBestEffort({t:String}) + INTERVAL 15 MINUTE
                AND content LIKE 'Cloud-init%'
                AND position(content, {needle:String}) > 0
            ORDER BY time LIMIT 1""", t=run_row["time"], needle=needle)
        cloud_init_log = rows[0]["content"] if rows else None
    return bench_log, cloud_init_log


def attach_logs(run_row):
    bench_log, cloud_init_log = fetch_logs(run_row)
    run_row["bench_url"] = pastila_post(bench_log)
    run_row["cloud_init_url"] = pastila_post(cloud_init_log)


def log_links(run_row):
    links = [f"[benchmark log]({run_row['bench_url']})" if run_row["bench_url"] else None,
             f"[cloud-init log]({run_row['cloud_init_url']})" if run_row["cloud_init_url"] else None]
    links = [link for link in links if link]
    return ", ".join(links) if links else "logs are not available"


# === git ===

def fetch_branch(ref, remote="origin", depth=200):
    """Fetch a branch from origin or from a fork's public URL."""
    run("git", "fetch", "-q", f"--depth={depth}", remote, f"+refs/heads/{ref}")
    return run("git", "rev-parse", "FETCH_HEAD")


def file_in_main(path):
    result = subprocess.run(["git", "show", f"origin/main:{path}"],
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def result_path(run_row):
    return "{system}/results/{date}/{machine}.json".format(**run_row)


def commit_results(base_sha, rows, removals, message, push_ref, force=False,
                   remote="origin"):
    """Create a commit with the result files on top of base_sha and push it.
    Returns the short commit hash, or None if there was nothing to change."""
    worktree = os.path.join(tempfile.mkdtemp(prefix="clickbench-results-"), "wt")
    run("git", "worktree", "add", "-q", "--detach", worktree, base_sha)
    try:
        for r in rows:
            path = os.path.join(worktree, result_path(r))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(r["output"])
            run("git", "-C", worktree, "add", result_path(r))
        for path in removals:
            run("git", "-C", worktree, "rm", "-q", "--ignore-unmatch", path)
        if not run("git", "-C", worktree, "status", "--porcelain"):
            return None
        run("git", "-C", worktree, "-c", f"user.name={BOT_NAME}",
            "-c", f"user.email={BOT_EMAIL}", "commit", "-q", "-m", message)
        sha = run("git", "-C", worktree, "rev-parse", "HEAD")
        auth = []
        if remote != "origin":
            # A push to a fork authenticates with the fork-push token. Two
            # subtleties: actions/checkout stores the workflow's GITHUB_TOKEN
            # as an http.<url>.extraheader in the local git config, which
            # would be sent to the fork too (and rejected), so it is cleared
            # for this push; and the token is handed over through an inline
            # credential helper that reads the environment variable, so it
            # never appears in a command line or in an error message.
            auth = ["-c", "http.https://github.com/.extraheader=",
                    "-c", "credential.helper=",
                    "-c", "credential.helper=!f() { echo username=x-access-token;"
                          ' echo "password=${CLICKBENCH_FORK_PUSH_TOKEN}"; }; f']
        if DRY_RUN:
            print(f"DRY_RUN: would push {sha} to {remote} {push_ref}")
        else:
            run("git", *auth, "-C", worktree, "push", "-q",
                *(["--force"] if force else []),
                remote, f"HEAD:refs/heads/{push_ref}")
        return sha[:10]
    finally:
        run("git", "worktree", "remove", "--force", worktree, check=False)


def manual_result_files(pr_number, systems, bot_paths):
    """Result files that the PR adds by hand: added for one of the systems,
    not written by this automation before, and not being written now."""
    files = gh_json("api", f"repos/{REPO}/pulls/{pr_number}/files",
                    "--paginate", "--slurp")
    removals = []
    for f in (item for page in files for item in page):
        name, status = f["filename"], f["status"]
        if status != "added" or name in bot_paths or ".." in name:
            continue
        if not any(name.startswith(f"{system}/results/") for system in systems):
            continue
        author = run("git", "log", "-1", "--format=%an", "FETCH_HEAD", "--", name,
                     check=False)
        if author != BOT_NAME:
            removals.append(name)
    return removals


# === processing ===

def is_clickhouse_variant(system):
    """ClickHouse's own systems, whose result PRs are trusted and auto-merged."""
    return system == "clickhouse" or system.startswith("clickhouse-")


def process_pr(pr_number, rows):
    meta = pr_meta(pr_number)
    if meta is None:
        note(f"PR #{pr_number}: not found, skipping {len(rows)} run(s)")
        return
    already = posted_text(pr_number, meta.get("body") or "")
    rows = [r for r in rows if marker(r) not in already]
    if not rows:
        return
    for r in rows:
        attach_logs(r)
    good = [r for r in rows if r["good"]]

    head_repo = (meta.get("head") or {}).get("repo") or {}
    same_repo = head_repo.get("full_name") == REPO
    # Forks are writable only with the fork-push token (see the module
    # docstring) and only while the PR author allows maintainer edits —
    # which GitHub does not offer at all for organization-owned forks.
    fork_push = (bool(FORK_PUSH_TOKEN) and not same_repo
                 and bool(head_repo.get("full_name"))
                 and bool(meta.get("maintainer_can_modify")))
    can_commit = bool(good) and meta["state"] == "open" and (same_repo or fork_push)

    commit = None
    removals = []
    if can_commit:
        head_ref = meta["head"]["ref"]
        remote = ("origin" if same_repo
                  else f"https://github.com/{head_repo['full_name']}.git")
        base_sha = fetch_branch(head_ref, remote=remote)
        systems = sorted({r["system"] for r in good})
        bot_paths = {result_path(r) for r in good}
        removals = manual_result_files(pr_number, systems, bot_paths)
        machines = ", ".join(sorted({r["machine"] for r in good}))
        try:
            commit = commit_results(base_sha, good, removals,
                                    f"Add benchmark results for {', '.join(systems)} ({machines})",
                                    head_ref, remote=remote)
        except RuntimeError as e:
            # A fork push can fail even though maintainer_can_modify said
            # yes: the author may have unticked it meanwhile, the branch may
            # have moved, or the fork may protect it. Fall back to posting
            # paste links instead of failing the whole PR.
            if same_repo:
                raise
            note(f"PR #{pr_number}: pushing to the fork failed: {e}")
            can_commit = False
            removals = []

    lines = []
    if good:
        by_system = {}
        for r in good:
            by_system.setdefault(r["system"], set()).add(r["machine"])
        for system, machines in sorted(by_system.items()):
            lines.append(f"Results for `{system}` are ready for: "
                         + ", ".join(f"`{m}`" for m in sorted(machines)) + ".")
        if commit:
            lines.append(f"The result files are committed as {commit}.")
        elif can_commit:
            lines.append("The result files are already in the branch.")
        elif good and not same_repo:
            for r in good:
                url = pastila_post(r["output"])
                lines.append(f"This pull request is from a fork, so the automation cannot "
                             f"push to it; save [this result]({url}) as `{result_path(r)}`.")
            if FORK_PUSH_TOKEN and not meta.get("maintainer_can_modify"):
                lines.append('Tick "Allow edits by maintainers" on the pull request '
                             "to let the automation commit the results itself.")
        if removals:
            lines.append("Removed manually added result files: "
                         + ", ".join(f"`{path}`" for path in removals) + ".")
    for system, machine in sorted({(r["system"], r["machine"]) for r in rows
                                   if not r["good"]}):
        lines.append(f"The run of `{system}` on `{machine}` did not produce results.")
    lines.append("")
    lines.append("Logs:")
    for r in rows:
        lines.append(f"- `{r['system']}` on `{r['machine']}`: {log_links(r)}")
    lines.append("")
    lines.extend(marker(r) for r in rows)

    post_comment(pr_number, "\n".join(lines))
    note(f"PR #{pr_number}: posted {len(rows)} run(s)"
         + (f", committed {commit}" if commit else ""))


def process_main(system, rows):
    if run("git", "rev-parse", "--verify", "-q", f"origin/main:{system}",
           check=False) == "":
        note(f"{system}: no such directory in main, skipping {len(rows)} run(s)")
        return
    # A result identical to what main already has was posted and merged before.
    rows = [r for r in rows
            if not (r["good"] and file_in_main(result_path(r)) == r["output"])]
    if not rows:
        return

    branch = f"auto-results/{system}"
    prs = gh_json("pr", "list", "--repo", REPO, "--head", branch,
                  "--state", "open", "--json", "number,body")
    pr = prs[0] if prs else None

    already = posted_text(pr["number"], pr.get("body") or "") if pr else ""
    rows = [r for r in rows if marker(r) not in already]
    good = [r for r in rows if r["good"]]
    failed = [r for r in rows if not r["good"]]
    if not good:
        # Nowhere to put logs of a failed run when no automated PR is open.
        for r in failed:
            if pr is None:
                note(f"{system}: run on {r['machine']} at {r['time']} "
                     "produced no results (no open PR to report to)")
        rows = failed if pr else []
        if not rows:
            return

    for r in rows:
        attach_logs(r)

    lines = []
    commit = None
    machines = sorted({r["machine"] for r in good})
    if good:
        message = f"Add results for {system} ({', '.join(machines)})"
        if pr:
            commit = commit_results(fetch_branch(branch), good, [], message, branch)
        else:
            commit = commit_results(run("git", "rev-parse", "origin/main"),
                                    good, [], message, branch, force=True)
    if good:
        lines.append(f"Results for `{system}` are ready for: "
                     + ", ".join(f"`{m}`" for m in machines) + ".")
        if commit:
            lines.append(f"The result files are committed as {commit}.")
    for machine in sorted({r["machine"] for r in failed}):
        lines.append(f"The run on `{machine}` did not produce results.")
    lines.append("")
    lines.append("Logs:")
    for r in rows:
        lines.append(f"- `{r['machine']}` at {r['time']}: {log_links(r)}")
    lines.append("")
    lines.extend(marker(r) for r in rows)
    body = "\n".join(lines)

    if pr:
        post_comment(pr["number"], body)
        note(f"{system}: updated PR #{pr['number']} with {len(rows)} run(s)")
    elif commit or DRY_RUN:
        if DRY_RUN:
            print(f"DRY_RUN: would create a PR for {branch}:\n{body}\n---")
        else:
            url = gh("pr", "create", "--repo", REPO, "--head", branch, "--base", "main",
                     "--title", f"Automated results for {system}", "--body", body)
            note(f"{system}: opened {url} with {len(rows)} run(s)")
            # ClickHouse's own result PRs are trusted; merge right after opening.
            if is_clickhouse_variant(system):
                try:
                    merge_pr(url)
                    note(f"{system}: auto-merged {url}")
                except RuntimeError as e:
                    note(f"{system}: auto-merge of {url} failed: {e}")


def main():
    if not DB_PASSWORD and not DRY_RUN:
        print("CLICKBENCH_DB_PASSWORD is not set. Skipping.")
        return 0
    run("git", "fetch", "-q", "origin", "main")

    runs = fetch_runs()
    print(f"Runs in the last day: {len(runs)}")

    by_pr = {}
    by_system = {}
    for r in runs:
        if r["pr"]:
            by_pr.setdefault(r["pr"], []).append(r)
        else:
            by_system.setdefault(r["system"], []).append(r)

    for pr_number, rows in sorted(by_pr.items()):
        try:
            process_pr(pr_number, rows)
        except Exception as e:
            errors.append(f"PR #{pr_number}: {e}")
    for system, rows in sorted(by_system.items()):
        try:
            process_main(system, rows)
        except Exception as e:
            errors.append(f"{system}: {e}")

    for error in errors:
        note(f"Error: {error}")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary and summary_lines:
        with open(step_summary, "a") as f:
            f.write("\n".join(summary_lines) + "\n")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
