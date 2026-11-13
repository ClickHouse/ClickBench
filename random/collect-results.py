#!/usr/bin/env python3
"""Writes the results of the groups of the randomized benchmark into the
repository: random/results/YYYYMMDD/<group>.json, one file per group (several
groups can run on a day), YYYYMMDD being the day the group was launched.

Usage: collect-results.py [--since-hours 24] [--group <id> ...] [--sink URL]

Takes every group with a result in the sink in the last --since-hours hours
(or the given groups) and writes its whole file again from the sink: the
results of a group arrive over hours, one machine after another. A file
holds:

  - the parameters of the group (rows, repeats, workers, timeout, seed, the
    ClickHouse version of the data and the reference, the model of the
    queries and the statistics of their generation),
  - the queries: SQL, features, description,
  - for every system and machine: the translations of the queries, the load
    time, the data size, the total and penalized time, the geomean (see
    lib/metrics.py), the counts, the reference times, and every run of every
    query (status, start, time, the time reported by the system, the error;
    for a wrong result, the beginning of the output),
  - the systems of the group without a result, with the error from the log
    of their machine.

Prints the paths of the files it wrote.
"""

import argparse
import base64
import gzip
import json
import os
import re
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import metrics  # noqa: E402

GROUP_RE = re.compile(r"^[0-9a-f-]{36}$")


def query(sink, sql):
    with urllib.request.urlopen(sink + "&query=" + urllib.parse.quote(sql), timeout=300) as response:
        return response.read().decode()


def rows(sink, sql):
    return [json.loads(line) for line in query(sink, sql + " FORMAT JSONEachRow").splitlines() if line]


def recent_groups(sink, since_hours):
    return [r["g"] for r in rows(sink, f"""
        SELECT DISTINCT JSONExtractString(content, 'group') AS g FROM sink.data
        WHERE time >= now() - INTERVAL {int(since_hours)} HOUR
          AND JSONExtractString(content, 'kind') = 'random-benchmark'""") if GROUP_RE.match(r["g"])]


def last_error(log):
    lines = [re.sub(r"\x1B\[[0-9;]*m", "", l).strip() for l in log.splitlines()]
    lines = [l for l in lines if l and not l.startswith("Exit status")]
    errors = [l for l in lines if re.match(r"^(ERROR|FATAL|PANIC|Error|error|Code: \d+|Traceback|Failed|random: \./check did not)", l)]
    mentions = [l for l in lines if re.search(r"(?i)(error|exception|fail|timeout|killed|denied|refus)", l)]
    return (errors or mentions or ["the run failed without a result"])[-1][:500]


def collect(sink, group):
    assert GROUP_RE.match(group)
    payload_rows = rows(sink, f"""
        SELECT content, toString(time) AS t FROM sink.data
        WHERE time >= now() - INTERVAL 60 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark-payload'
          AND JSONExtractString(content, 'group') = '{group}'
        ORDER BY time""")
    payloads, launched = {}, None
    for row in payload_rows:
        p = json.loads(row["content"])
        # The earliest payload of a system: the launcher stores it before the machines start.
        if p.get("system") in payloads:
            continue
        try:
            payloads[p["system"]] = json.loads(gzip.decompress(base64.b64decode(p["data"])))
        except (ValueError, OSError, KeyError):
            continue
        launched = launched or row["t"]
    results = [json.loads(r["content"]) for r in rows(sink, f"""
        SELECT content FROM sink.data
        WHERE time >= now() - INTERVAL 60 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark'
          AND JSONExtractString(content, 'group') = '{group}'
        ORDER BY time""")]
    logs = rows(sink, f"""
        SELECT extract(content, 'system: ([a-z0-9_.-]+)') AS system,
               extract(content, 'Exit status: [0-9]+, instance type: ([a-z0-9.-]+),') AS machine,
               content, toString(time) AS t
        FROM sink.data
        WHERE time >= now() - INTERVAL 60 DAY
          AND startsWith(content, 'Randomized benchmark group: {group}, system: ')
        ORDER BY time""")
    if not results and not logs:
        return None

    # The latest result of every (system, machine).
    latest = {}
    for r in results:
        latest[(r["machine"], r["directory"])] = r
    first = results[0] if results else {}
    meta = next(iter(payloads.values()))["queries"] if payloads else {}

    systems = []
    for machine in sorted({m for m, _ in latest}):
        here = [r for (m, _), r in latest.items() if m == machine]
        geo = metrics.geomeans(here)
        for r in sorted(here, key=lambda r: (geo[r["directory"]] is None, geo[r["directory"]] or 0)):
            translated = payloads.get(r["directory"], {}).get("translated", {})
            runs = []
            for e in r["executions"]:
                run = {k: e.get(k) for k in ("id", "repeat", "status", "start", "time", "reported_time")}
                if e.get("detail"):
                    run["detail"] = e["detail"]
                if e["status"] == "wrong" and e["repeat"] == 1 and e["id"] in r.get("outputs", {}):
                    run["output"] = r["outputs"][e["id"]]
                runs.append(run)
            systems.append({
                "directory": r["directory"], "system": r.get("system"), "machine": machine,
                "proprietary": r.get("proprietary"), "tuned": r.get("tuned"), "tags": r.get("tags", []),
                "repo": r.get("repo"), "branch": r.get("branch"), "commit": r.get("commit"),
                "translator": r.get("translator") or translated.get("translator"),
                "translations": {q["id"]: q["sql"] for q in translated.get("queries", [])},
                "load_time": r.get("load_time"), "data_size": r.get("data_size"),
                "data_size_after": r.get("data_size_after"),
                "total_time": r["total_time"], "penalized_time": round(metrics.penalized_time(r), 3),
                "geomean": round(geo[r["directory"]], 4) if geo[r["directory"]] is not None else None,
                "counts": r["counts"], "error_rate": r.get("error_rate"), "restarts": r.get("restarts", 0),
                "reference": r.get("reference", {}), "runs": runs,
            })

    # The systems of the group without a result: the error from their log.
    with_result = {r["directory"] for r in results}
    missing = []
    for system in sorted(set(payloads) - with_result):
        log = next((l for l in reversed(logs) if l["system"] == system), None)
        missing.append({"directory": system, "machine": log["machine"] if log else None,
                        "error": last_error(log["content"]) if log else "no result and no log yet"})

    day = (launched or (logs[0]["t"] if logs else "")).split(" ")[0]
    return {
        "group": group, "date": day, "launched": launched,
        "rows": first.get("rows"), "repeats": first.get("repeats"), "parallel": first.get("parallel"),
        "query_timeout": first.get("query_timeout"), "seed": first.get("seed"),
        "clickhouse_version": first.get("clickhouse_version"),
        "generation": {k: meta.get(k) for k in ("model", "generated", "valid", "rejected", "coverage")},
        "queries": [{k: q.get(k) for k in ("id", "sql", "features", "description")} for q in meta.get("queries", [])],
        "systems": systems, "missing": missing,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--since-hours", type=int, default=24)
    parser.add_argument("--group", nargs="*")
    parser.add_argument("--sink", default="https://play.clickhouse.com/?user=sink")
    args = parser.parse_args()
    groups = args.group or recent_groups(args.sink, args.since_hours)
    for group in groups:
        data = collect(args.sink, group)
        if data is None or not data["date"]:
            print(f"collect: nothing for {group}", file=sys.stderr)
            continue
        path = os.path.join(HERE, "results", data["date"].replace("-", ""), f"{group}.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(data, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print(os.path.relpath(path, os.path.dirname(HERE)))


if __name__ == "__main__":
    main()
