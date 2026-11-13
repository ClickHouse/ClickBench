#!/usr/bin/env python3
"""Compares the systems of a group of the randomized benchmark.

Usage:
  report.py <group> [--sink URL] [--files result.json ...] [--output dir]
            [--payloads payload.json ...] [--publish]

Reads the results of the group from the sink (kind "random-benchmark"), or
from files, and prints a Markdown report: one table per machine type, and
the queries with the most failures. With --output, also writes report.md,
report.html (the self-contained HTML report, see lib/report_html.py) and
results.json (all results) into the directory. The queries and their
translations for the HTML report come from the payloads of the group in the
sink (the earliest one of every system: the launcher stores them before it
launches the machines), or from --payloads files (payload rows, or the
directory groups/<group>/payload/ of a local launch). With --publish, the
HTML report is posted to pastila.nl (as results_preview.py does) and the
link is printed and added to the job summary.

The queries are random, so the numbers are comparable only within a group:
the same queries and the same data for every system and machine.

Columns:
  Geomean         the geometric mean of the times relative to the best system,
                  as on the ClickBench page but with the average time of every
                  query, failures counting as 5x the slowest correct execution
                  (see lib/metrics.py); the systems are ranked by it
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

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import metrics  # noqa: E402
import revalidate  # noqa: E402
import report_html  # noqa: E402

FAILED = ("wrong", "error", "timeout", "unsupported")


def fetch(sink, group):
    query = f"""SELECT content FROM sink.data
        WHERE time >= now() - INTERVAL 30 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark'
          AND JSONExtractString(content, 'group') = '{group}'
        ORDER BY time FORMAT JSONEachRow"""
    with urllib.request.urlopen(sink + "&query=" + urllib.parse.quote(query), timeout=300) as response:
        return [json.loads(json.loads(line)["content"]) for line in response.read().decode().splitlines() if line]


def decode_payload(row):
    import base64
    import gzip
    return json.loads(gzip.decompress(base64.b64decode(row["data"])))


def fetch_payloads(sink, group):
    """{system: {"queries": ..., "translated": ...}} of the group."""
    query = f"""SELECT content FROM sink.data
        WHERE time >= now() - INTERVAL 30 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark-payload'
          AND JSONExtractString(content, 'group') = '{group}'
        ORDER BY time FORMAT JSONEachRow"""
    with urllib.request.urlopen(sink + "&query=" + urllib.parse.quote(query), timeout=300) as response:
        rows = [json.loads(json.loads(line)["content"]) for line in response.read().decode().splitlines() if line]
    payloads = {}
    for row in rows:
        if row.get("system") not in payloads:
            try:
                payloads[row["system"]] = decode_payload(row)
            except (ValueError, OSError, KeyError):
                print(f"report: an undecodable payload row for {row.get('system')}, skipped", file=sys.stderr)
    return payloads


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
        here = [r for (m, _), r in latest.items() if m == machine]
        geo = metrics.geomeans(here)
        rows = sorted(here, key=lambda r: (geo[r["directory"]] is None, geo[r["directory"]] or 0))
        lines += [f"## {machine}", "",
                  "| System | Geomean | Total time | Penalized time | OK | Wrong | Errors | Unverified | Load time | Data size |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for r in rows:
            counts = r["counts"]
            errors = sum(counts.get(s, 0) for s in ("error", "timeout", "unsupported"))
            load = f"{r['load_time']:.0f} s" if isinstance(r.get("load_time"), (int, float)) else "-"
            g = geo[r["directory"]]
            lines.append(f"| {r['directory']} | {g:.2f} | {r['total_time']:.0f} s | {metrics.penalized_time(r):.0f} s | "
                         f"{counts.get('ok', 0)} | {counts.get('wrong', 0)} | {errors} | {counts.get('unverified', 0)} | "
                         f"{load} | {human_size(r.get('data_size'))} |" if g is not None else
                         f"| {r['directory']} | - | {r['total_time']:.0f} s | {metrics.penalized_time(r):.0f} s | - | - | - | - | {load} | - |")
        lines += ["", "Geomean: for every query, the average time of the system (a failed execution counts as 5x the "
                  "slowest correct execution of the query in the group), relative to the best system's average as "
                  "(0.01 + time) / (0.01 + best); the geometric mean over the queries. Lower is better; 1 is the best "
                  "on every query.", ""]
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
    parser.add_argument("--payloads", nargs="*")
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    if args.files:
        results = [json.load(open(f)) for f in args.files]
    else:
        results = fetch(args.sink, args.group)
    # The statuses of the current validator, where the machine sent its outputs.
    for r in results:
        revalidate.revalidate(r)
    if args.payloads is not None:
        payloads = {}
        for f in args.payloads:
            row = json.load(open(f))
            payloads[row["system"]] = decode_payload(row)
    elif args.files:
        payloads = {}
    else:
        payloads = fetch_payloads(args.sink, args.group)
    text = report(results, args.group)
    print(text)
    if args.output:
        os.makedirs(args.output, exist_ok=True)
        with open(os.path.join(args.output, "report.md"), "w") as f:
            f.write(text + "\n")
        with open(os.path.join(args.output, "results.json"), "w") as f:
            json.dump(results, f, ensure_ascii=False)
        if results:
            with open(os.path.join(args.output, "report.html"), "w") as f:
                f.write(report_html.render(results, payloads))
    if args.publish and results:
        sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        import pastila
        url = pastila.post(report_html.render(results, payloads), extension=".html", compress=True)
        print(f"\nHTML report: {url}")
        text += f"\n\nHTML report: {url}\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
