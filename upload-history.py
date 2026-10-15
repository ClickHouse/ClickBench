#!/usr/bin/env python3
"""Upload all the results to play.clickhouse.com for the history view of the website.

The table clickbench.results (see prepare-database.sql) has a row for every
result file of the repository, <system>/results/<date>/<name>.json, with the
fields of the JSON in columns. The script replaces its
content atomically: it loads the files into clickbench.results_staging and
moves them over with ALTER TABLE REPLACE PARTITION.

play.clickhouse.com has multiple replicas behind a load balancer. The staging
table is a plain MergeTree on each of them, so the replica that replaces the
partition must be the one that got the inserted rows: all the statements run
in a single invocation of clickhouse-client, over one connection to one
replica, and the number of rows in the staging table is checked before moving
it. The other replicas fetch the new parts of clickbench.results from it.

The upload is skipped if the table already has the same files: a fingerprint
of the paths and git blob ids of the files is compared with the one computed by
the server from the table. So it is cheap to run often - see
.github/workflows/upload-history.yml. Set FORCE=1 to upload anyway, e.g. after
changing the columns.

Environment:
    CLICKBENCH_UPLOAD_PASSWORD - the password of the user (required);
    CLICKBENCH_UPLOAD_USER - default: clickbench_upload;
    CLICKBENCH_UPLOAD_HOST - default: play.clickhouse.com;
    CLICKBENCH_UPLOAD_SECURE - TLS, HTTPS on 443 and native on 9440; set to 0
        for plain HTTP on 8123 and native on 9000, e.g. to test with a local server;
    DRY_RUN=1 - prepare the data and print the statements, but don't run them.

Requires a checkout of the repository as the working directory. Uses
`clickhouse` from PATH, or downloads it, if the upload is needed.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

HOST = os.environ.get("CLICKBENCH_UPLOAD_HOST") or "play.clickhouse.com"
SECURE = os.environ.get("CLICKBENCH_UPLOAD_SECURE", "1") != "0"
USER = os.environ.get("CLICKBENCH_UPLOAD_USER") or "clickbench_upload"
PASSWORD = os.environ.get("CLICKBENCH_UPLOAD_PASSWORD") or ""
FORCE = bool(os.environ.get("FORCE"))
DRY_RUN = bool(os.environ.get("DRY_RUN"))

TABLE = "clickbench.results"
STAGING = "clickbench.results_staging"

# The same files as in generate-results.sh: <system>/results/<date>/<name>.json.
RESULT_RE = re.compile(r"([^/]+)/results/([^/]+)/([^/]+\.json)$")
SKIP_SYSTEMS = {"hardware", "versions", "gravitons"}
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}$")


def result_files():
    """[(path, blob id)] of the result files in the index, sorted by path."""
    out = subprocess.run(["git", "ls-files", "-s", "-z"], capture_output=True, check=True).stdout
    files = []
    for line in out.decode().split("\0"):
        if not line:
            continue
        meta, path = line.split("\t", 1)
        mode, blob, _stage = meta.split()
        match = RESULT_RE.match(path)
        # Symlinks and submodules are not results.
        if match and match.group(1) not in SKIP_SYSTEMS and mode in ("100644", "100755"):
            files.append((path, blob))
    return sorted(files)


def number(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def make_row(path, blob):
    """The row of the table for a file, or None if it is not a JSON object."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except ValueError as e:
        print(f"Skipping {path}: {e}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(f"Skipping {path}: not an object", file=sys.stderr)
        return None

    directory, run, name = RESULT_RE.match(path).groups()
    date = data.get("date") if isinstance(data.get("date"), str) and DATE_RE.match(data.get("date")) else None
    file_date = f"{run[0:4]}-{run[4:6]}-{run[6:8]}" if re.fullmatch(r"\d{8}", run) else date or "1970-01-01"

    def string(key):
        value = data.get(key)
        return "" if value is None else value if isinstance(value, str) else json.dumps(value)

    data_size = data.get("data_size")
    result = data.get("result")
    return {
        "source": path,
        "blob": blob,
        "directory": directory,
        "name": name,
        "file_date": file_date,
        "system": string("system"),
        "date": date or file_date,
        "machine": string("machine"),
        "cluster_size": string("cluster_size"),
        "proprietary": string("proprietary"),
        "hardware": string("hardware"),
        "tuned": string("tuned"),
        "tags": [tag for tag in data.get("tags") or [] if isinstance(tag, str)],
        "comment": string("comment"),
        "load_time": number(data.get("load_time")),
        "data_size": int(data_size) if number(data_size) is not None and data_size >= 0 else None,
        "concurrent_qps": number(data.get("concurrent_qps")),
        "concurrent_error_ratio": number(data.get("concurrent_error_ratio")),
        "result": [[number(t) for t in timings] if isinstance(timings, list) else []
                   for timings in result] if isinstance(result, list) else [],
        "error": string("error"),
    }


def fingerprint(rows):
    """Must match the query in uploaded_fingerprint."""
    lines = sorted(f"{row['source']} {row['blob']}" for row in rows)
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()


def uploaded_fingerprint():
    sql = (f"SELECT lower(hex(SHA256(arrayStringConcat(arraySort(groupArray(source || ' ' || blob)), '\\n'))))"
           f" FROM {TABLE}")
    # The URL must carry a query parameter: play.clickhouse.com redirects the bare / to the UI.
    url = (f"https://{HOST}/" if SECURE else f"http://{HOST}:8123/") + "?" + urllib.parse.urlencode(
        {"default_format": "TabSeparated"})
    request = urllib.request.Request(url, data=sql.encode(), headers={
        "X-ClickHouse-User": USER, "X-ClickHouse-Key": PASSWORD})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode().strip()


def clickhouse_binary(tmp):
    found = shutil.which("clickhouse")
    if found:
        return found
    print("Downloading ClickHouse")
    subprocess.run("curl -sSfL https://clickhouse.com/ | sh", shell=True, cwd=tmp, check=True,
                   stdout=subprocess.DEVNULL)
    return os.path.join(tmp, "clickhouse")


def quote(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'") + "'"


def main():
    if not PASSWORD and not DRY_RUN:
        print("CLICKBENCH_UPLOAD_PASSWORD is not set. Skipping.")
        return

    rows = [row for row in (make_row(path, blob) for path, blob in result_files()) if row]
    local = fingerprint(rows)
    print(f"{len(rows)} result files, fingerprint {local}")

    if not FORCE and not DRY_RUN:
        uploaded = uploaded_fingerprint()
        if uploaded == local:
            print("The table is up to date.")
            return
        print(f"The table has fingerprint {uploaded}, uploading.")

    with tempfile.TemporaryDirectory() as tmp:
        data_path = os.path.join(tmp, "results.jsonl")
        with open(data_path, "w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

        # The staging table is local and REPLACE PARTITION waits for the
        # current replica by default, so every statement sees the result of
        # the previous one.
        script = f"""
TRUNCATE TABLE {STAGING};
INSERT INTO {STAGING} FROM INFILE {quote(data_path)} FORMAT JSONEachRow;
SELECT throwIf(count() != {len(rows)}, 'The staging table has an unexpected number of rows') FROM {STAGING} FORMAT Null;
ALTER TABLE {TABLE} REPLACE PARTITION tuple() FROM {STAGING};
"""
        if DRY_RUN:
            print(script)
            print(f"Data: {os.path.getsize(data_path)} bytes")
            return

        command = [clickhouse_binary(tmp), "client", "--host", HOST, "--user", USER,
                   "--multiquery", "--query", script]
        if SECURE:
            command.append("--secure")
        subprocess.run(command, check=True, env={**os.environ, "CLICKHOUSE_PASSWORD": PASSWORD})

    uploaded = uploaded_fingerprint()
    if uploaded != local:
        # Can be a lagging replica behind the load balancer, but more likely a bug.
        print(f"Warning: after the upload, the table has fingerprint {uploaded}", file=sys.stderr)
    print("Uploaded.")


if __name__ == "__main__":
    main()
