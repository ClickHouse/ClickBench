#!/usr/bin/env python3
"""Publish a preview of the benchmark page with the results of a pull request.

The preview is the website's index.html with the data of generate-results.sh
embedded into it, for the results of the base branch (origin/main) with the
result files of the pull request laid over them. It is published on
pastila.nl unencrypted, as a gzipped .html paste, and the link is posted on
the pull request: appended to the last comment if that is a comment of this
automation (collect-new-results.py also puts the link into its comments),
otherwise as a new comment.

Everything is read from git objects - the PR head is fetched, never checked
out, and no code from it runs - so this is safe to run for PRs from forks
in pull_request_target (see .github/workflows/results-preview.yml).

Usage: results_preview.py <pr-number>, in a checkout of the repository, with
GH_TOKEN for `gh`. Set DRY_RUN=1 to print actions instead of performing them.
"""

import json
import os
import re
import subprocess
import sys

import pastila

REPO = os.environ.get("GITHUB_REPOSITORY") or "ClickHouse/ClickBench"
DRY_RUN = bool(os.environ.get("DRY_RUN"))
BOT_LOGIN = "github-actions[bot]"
MARKER = "<!-- clickbench-preview -->"
# Comments of collect-new-results.py, which the link is appended to.
COLLECT_MARKER = "<!-- clickbench-collect: "

# The same files as in generate-results.sh: <system>/results/<date>/<name>.json.
RESULT_RE = re.compile(r"([^/]+)/results/([^/]+)/([^/]+\.json)$")
SKIP_SYSTEMS = {"hardware", "versions", "gravitons"}
DATA_SCRIPT = '<script type="text/javascript" src="data.generated.js"></script>'


def git(*args, input=None):
    result = subprocess.run(["git", *args], capture_output=True, input=input)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.decode().strip()}")
    return result.stdout


def result_files(rev):
    """{path: blob id} of the result files in a commit."""
    files = {}
    for line in git("ls-tree", "-r", "-z", rev).decode().split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        mode, kind, oid = meta.split()
        # Symlinks and submodules are not results.
        if kind == "blob" and mode in ("100644", "100755") and RESULT_RE.match(path):
            files[path] = oid
    return files


def read_blobs(oids):
    """{blob id: content} via a single `git cat-file --batch`."""
    oids = list(dict.fromkeys(oids))
    out = git("cat-file", "--batch", input="".join(o + "\n" for o in oids).encode())
    blobs = {}
    pos = 0
    for oid in oids:
        end = out.index(b"\n", pos)
        size = int(out[pos:end].split()[2])
        blobs[oid] = out[end + 1:end + 1 + size]
        pos = end + 1 + size + 1
    return blobs


def generate_data(files):
    """The data array of the website, as built by generate-results.sh from
    {path: content}: the latest dated copy per (system, file name), without
    failed runs ({"error": ...}) and entries tagged "historical"."""
    latest = {}
    for path in sorted(files):
        m = RESULT_RE.match(path)
        if m and m.group(1) not in SKIP_SYSTEMS:
            latest[(m.group(1), m.group(3))] = path
    data = []
    for path in sorted(latest.values()):
        try:
            entry = json.loads(files[path])
        except ValueError:
            print(f"Error in {path} - skipping", file=sys.stderr)
            continue
        if not isinstance(entry, dict) or entry.get("error") is not None:
            continue
        if "historical" in (entry.get("tags") or []):
            continue
        if not entry.get("date"):
            date_dir = RESULT_RE.match(path).group(2)
            entry["date"] = f"{date_dir[:4]}-{date_dir[4:6]}-{date_dir[6:8]}"
        entry["source"] = path
        data.append(entry)
    return data


def build_page(base, changes):
    """index.html of the base revision with the data embedded, for the result
    files of the base revision updated with changes: {path: content, or None
    for a removed file}."""
    oids = result_files(base)
    for path in changes:
        oids.pop(path, None)
    blobs = read_blobs(oids.values())
    files = {path: blobs[oid] for path, oid in oids.items()}
    files.update({path: content for path, content in changes.items() if content is not None})

    page = git("show", f"{base}:index.html").decode()
    if DATA_SCRIPT not in page:
        raise RuntimeError("index.html does not load data.generated.js")
    # Results come from pull requests: escape "<" so that no string in them
    # can close the script element.
    data = json.dumps(generate_data(files), ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    script = f'<script type="text/javascript">\nconst data = {data};\n</script>'
    return page.replace(DATA_SCRIPT, script, 1)


def publish(base, changes):
    """Publish the preview page and return its URL."""
    return pastila.post(build_page(base, changes), extension=".html", compress=True)


def preview_line(url):
    return f"[Preview of the benchmark page with these results]({url}) {MARKER}"


def pr_changes(pr_number, head):
    """{path: content or None} of the result files that the PR adds, changes
    or removes, with the contents at the head commit (which must be fetched)."""
    pages = json.loads(subprocess.run(
        ["gh", "api", f"repos/{REPO}/pulls/{pr_number}/files", "--paginate", "--slurp"],
        capture_output=True, text=True, check=True).stdout)
    paths = set()
    for f in (item for page in pages for item in page):
        paths.add(f["filename"])
        if f.get("previous_filename"):
            paths.add(f["previous_filename"])
    head_files = result_files(head)
    paths = {p for p in paths if RESULT_RE.match(p)}
    blobs = read_blobs(head_files[p] for p in paths if p in head_files)
    return {p: blobs[head_files[p]] if p in head_files else None for p in paths}


def with_preview(body, url):
    """A comment body with the preview line added, replacing an older one."""
    lines = [line for line in body.split("\n") if MARKER not in line]
    while lines and not lines[-1].strip():
        lines.pop()
    return "\n".join(lines) + "\n\n" + preview_line(url)


def post_link(pr_number, url):
    comments = json.loads(subprocess.run(
        ["gh", "api", f"repos/{REPO}/issues/{pr_number}/comments", "--paginate", "--slurp"],
        capture_output=True, text=True, check=True).stdout)
    comments = [c for page in comments for c in page]
    last = comments[-1] if comments else None
    if (last and last["user"]["login"] == BOT_LOGIN
            and (MARKER in last["body"] or COLLECT_MARKER in last["body"])):
        if url in last["body"]:
            print(f"The last comment already links to {url}")
            return
        body = with_preview(last["body"], url)
        cmd = ["gh", "api", "-X", "PATCH", f"repos/{REPO}/issues/comments/{last['id']}",
               "-f", "body=" + body]
    else:
        body = preview_line(url)
        cmd = ["gh", "api", f"repos/{REPO}/issues/{pr_number}/comments", "-f", "body=" + body]
    if DRY_RUN:
        print(f"DRY_RUN: would run {cmd[:4]} with:\n{body}\n---")
        return
    subprocess.run(cmd, capture_output=True, check=True)


def main():
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print(__doc__)
        return 1
    pr_number = sys.argv[1]
    git("fetch", "-q", "--depth=1", "origin", "main")
    base = git("rev-parse", "FETCH_HEAD").decode().strip()
    git("fetch", "-q", "--depth=1", "origin", f"refs/pull/{pr_number}/head")
    head = git("rev-parse", "FETCH_HEAD").decode().strip()

    changes = pr_changes(pr_number, head)
    if not changes:
        print("The pull request does not change any results.")
        return 0
    url = publish(base, changes)
    print(f"Preview: {url}")
    post_link(pr_number, url)
    return 0


if __name__ == "__main__":
    sys.exit(main())
