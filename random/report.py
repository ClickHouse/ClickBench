#!/usr/bin/env python3
"""Compares the systems of a group of the randomized benchmark.

Usage:
  report.py <group> [--sink URL] [--files result.json ...] [--output dir]

Reads the results of the group from the sink (kind "random-benchmark"), or
from files, and prints a Markdown report: one table per machine type, and
the queries with the most failures. With --output, also writes report.md and
results.json (all results) into the directory.

The queries are random, so the numbers are comparable only within a group:
the same queries and the same data for every system and machine.

Columns:
  Total time      the wall clock time of all executions (queries x repeats)
                  with the concurrent workers
  Penalized time  the total time plus the query timeout for every failed
                  execution, divided by the number of workers: a failure is
                  as bad as the slowest possible answer
  Wrong           executions with a result different from the reference
  Errors          errors, timeouts, and queries the system can't express
  Unverified      results without a reference result to compare with
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

FAILED = ("wrong", "error", "timeout", "unsupported")


def fetch(sink, group):
    query = f"""SELECT content FROM sink.data
        WHERE time >= now() - INTERVAL 30 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark'
          AND JSONExtractString(content, 'group') = '{group}'
        ORDER BY time FORMAT JSONEachRow"""
    with urllib.request.urlopen(sink + "&query=" + urllib.parse.quote(query), timeout=300) as response:
        return [json.loads(json.loads(line)["content"]) for line in response.read().decode().splitlines() if line]


def human_size(n):
    if not isinstance(n, (int, float)):
        return "-"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1000:
            return f"{n:.1f} {unit}"
        n /= 1000
    return f"{n:.1f} PB"


def report(results, group):
    lines = [f"# Randomized benchmark, group {group}", ""]
    if not results:
        return "\n".join(lines + ["No results yet."])
    first = results[0]
    lines.append(f"{first['rows']:,} rows, {len({e['id'] for e in first['executions']})} queries x "
                 f"{first['repeats']} repeats, {first['parallel']} concurrent workers, "
                 f"query timeout {first['query_timeout']} s, reference ClickHouse {first['clickhouse_version']}.")
    lines.append("")
    # The latest result of every (system, machine).
    latest = {}
    for r in results:
        latest[(r["machine"], r["directory"])] = r
    for machine in sorted({m for m, _ in latest}):
        rows = []
        for (m, directory), r in latest.items():
            if m != machine:
                continue
            counts = r["counts"]
            failed = sum(counts.get(s, 0) for s in FAILED)
            penalized = r["total_time"] + failed * r["query_timeout"] / r["parallel"]
            rows.append((penalized, directory, r, counts, failed))
        rows.sort(key=lambda x: x[0])
        lines += [f"## {machine}", "",
                  "| System | Penalized time | Total time | OK | Wrong | Errors | Unverified | Load time | Data size |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for penalized, directory, r, counts, failed in rows:
            errors = sum(counts.get(s, 0) for s in ("error", "timeout", "unsupported"))
            load = f"{r['load_time']:.0f} s" if isinstance(r.get("load_time"), (int, float)) else "-"
            lines.append(f"| {directory} | {penalized:.0f} s | {r['total_time']:.0f} s | {counts.get('ok', 0)} | "
                         f"{counts.get('wrong', 0)} | {errors} | {counts.get('unverified', 0)} | {load} | "
                         f"{human_size(r.get('data_size'))} |")
        lines.append("")
    # Queries where many systems fail: either hard queries, or a problem with
    # the query or the reference when nearly every system disagrees with it.
    per_query = {}
    for r in latest.values():
        for e in r["executions"]:
            per_query.setdefault(e["id"], {}).setdefault(r["directory"], set()).add(e["status"])
    systems = sorted({d for _, d in latest})
    table = []
    flagged = []
    for qid in sorted(per_query):
        statuses = per_query[qid]
        cells = []
        for s in systems:
            st = statuses.get(s, set())
            worst = next((x for x in ("wrong", "error", "timeout", "unsupported", "unverified") if x in st), "ok")
            cells.append({"ok": "", "wrong": "W", "error": "E", "timeout": "T", "unsupported": "U",
                          "unverified": "?"}[worst])
        if any(cells):
            table.append(f"| {qid} | " + " | ".join(cells) + " |")
        wrong = sum(1 for s in systems if "wrong" in statuses.get(s, set()))
        if len(systems) >= 3 and wrong > len(systems) / 2:
            flagged.append(qid)
    lines += ["## Queries with failures", ""]
    if table:
        lines += ["| Query | " + " | ".join(systems) + " |", "|---|" + "---|" * len(systems)] + table
        lines += ["", "W: wrong result, E: error, T: timeout, U: unsupported, ?: no reference result.", ""]
    else:
        lines += ["None: every execution of every system returned the reference result.", ""]
    if flagged:
        lines += [f"Most systems disagree with the reference on: {', '.join(flagged)}. "
                  "Check these queries and the reference before drawing conclusions.", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("group")
    parser.add_argument("--sink", default="https://play.clickhouse.com/?user=sink")
    parser.add_argument("--files", nargs="*")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.files:
        results = [json.load(open(f)) for f in args.files]
    else:
        results = fetch(args.sink, args.group)
    text = report(results, args.group)
    print(text)
    if args.output:
        os.makedirs(args.output, exist_ok=True)
        with open(os.path.join(args.output, "report.md"), "w") as f:
            f.write(text + "\n")
        with open(os.path.join(args.output, "results.json"), "w") as f:
            json.dump(results, f, ensure_ascii=False)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
