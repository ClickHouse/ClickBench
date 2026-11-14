"""The requirements of the "Production" category that the randomized benchmark checks.

From the README of ClickBench, a Production system:
  - "changing benchmark queries does not lead to crashes or deadlocks";
  - "changing benchmark queries does not widen the performance gap to the
    baseline by more than two times compared to ClickHouse".

The randomized benchmark changes the queries (and the data), so it checks both
for every system of a group, on every machine type:

Crashes and deadlocks: the system went down during the run (the driver
restarted it), an execution failed with a lost connection or a crash of the
server, or an execution ran into the query timeout (a hang, or a query slower
than the timeout, which is as bad for a user). A system of the group without
a result (it failed to install, load, or run) fails too: there is nothing to
qualify it with.

The gap: on the randomized queries, the geometric mean over the queries of
(0.01 + average time of the system) / (0.01 + average time of ClickHouse), with
the failures counting as in lib/metrics.py; on the standard queries, the same
ratio of the hot times (the best of the second and third runs) of the latest
results of the system and of ClickHouse in the main benchmark on the same
machine type (queries without a result on either side are skipped). The gap
widens by random gap / standard gap; more than 2 fails.

The baseline is the "clickhouse" entry of the group; the standard gap of a
directory is taken from the directory of the same name in the main benchmark.
"""

import glob
import json
import math
import os
import re

import metrics

CLICKBENCH_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASELINE = "clickhouse"
MAX_WIDENING = 2.0

# Errors that mean the server is gone, not that it refused the query.
CRASH = re.compile(r"connection (?:refused|reset|closed|lost|aborted)|server closed the connection|"
                   r"broken pipe|segmentation fault|sigsegv|core dumped|terminated abnormally|"
                   r"terminating connection|unexpected eof|end of file|no route to host|"
                   r"could not connect|failed to connect|cannot connect|can't connect|"
                   r"remotedisconnected|connectionerror|killed", re.IGNORECASE)


def category(directory):
    try:
        with open(os.path.join(CLICKBENCH_DIR, directory, "template.json")) as f:
            return json.load(f).get("category")
    except (OSError, ValueError):
        return None


def main_result(directory, machine):
    """The latest untuned result of the directory on the machine type in the main benchmark."""
    best = None
    for path in glob.glob(os.path.join(CLICKBENCH_DIR, directory, "results", "*", "*.json")):
        try:
            with open(path) as f:
                r = json.load(f)
        except (OSError, ValueError):
            continue
        if r.get("machine") != machine or r.get("tuned") == "yes" or not isinstance(r.get("result"), list):
            continue
        if best is None or r.get("date", "") > best.get("date", ""):
            best = r
    return best


def hot(runs):
    tries = [t for t in runs[1:] if isinstance(t, (int, float))]
    return min(tries) if tries else None


def standard_gap(directory, machine):
    """(gap, date of the system's result, date of ClickHouse's) or None."""
    system, baseline = main_result(directory, machine), main_result(BASELINE, machine)
    if system is None or baseline is None:
        return None
    logs = []
    for a, b in zip(system["result"], baseline["result"]):
        a, b = hot(a), hot(b)
        if a is not None and b is not None:
            logs.append(math.log((metrics.CONSTANT_TIME_ADD + a) / (metrics.CONSTANT_TIME_ADD + b)))
    if not logs:
        return None
    return math.exp(sum(logs) / len(logs)), system.get("date"), baseline.get("date")


def random_gaps(results):
    """{directory: gap to the baseline} for the results of one machine type."""
    penalties = metrics.failure_times(results)
    averages = {r["directory"]: metrics.average_times(r, penalties) for r in results}
    base = averages.get(BASELINE)
    if base is None:
        return {}
    out = {}
    for d, a in averages.items():
        logs = [math.log((metrics.CONSTANT_TIME_ADD + a[q]) / (metrics.CONSTANT_TIME_ADD + base[q]))
                for q in sorted(penalties) if q in a and q in base]
        out[d] = math.exp(sum(logs) / len(logs)) if logs else None
    return out


def crashes(result):
    """(restarts, executions failed with a crash or a lost connection, timeouts)."""
    crashed = sum(1 for e in result["executions"]
                  if e["status"] == "error" and CRASH.search(e.get("detail") or e.get("error") or ""))
    return result.get("restarts", 0), crashed, result["counts"].get("timeout", 0)


def check(results, machine, missing=()):
    """The verdict for every system of one machine type: a list of dicts,
    in the order of the results, then the missing systems."""
    gaps = random_gaps(results)
    out = []
    for r in results:
        d = r["directory"]
        restarts, crashed, timeouts = crashes(r)
        reasons = []
        if restarts:
            reasons.append(f"went down {restarts} times")
        if crashed:
            reasons.append(f"{crashed} executions lost the server")
        if timeouts:
            reasons.append(f"{timeouts} executions hit the timeout of {r['query_timeout']} s")
        gap = gaps.get(d)
        standard = standard_gap(d, machine) if d != BASELINE else (1.0, None, None)
        widening = gap / standard[0] if gap is not None and standard is not None else None
        if widening is None:
            reasons.append("no gap to compare: " + ("no ClickHouse in the group" if gap is None else
                                                    f"no result in the main benchmark on {machine}"))
        elif widening > MAX_WIDENING:
            reasons.append(f"the gap to ClickHouse widens {widening:.1f} times")
        out.append({"directory": d, "category": category(d), "restarts": restarts, "crashed": crashed,
                    "timeouts": timeouts, "random_gap": gap, "standard_gap": standard[0] if standard else None,
                    "standard_date": standard[1] if standard else None, "widening": widening,
                    "passes": not reasons, "reasons": reasons})
    for m in missing:
        if m.get("machine") in (None, machine):
            out.append({"directory": m["directory"], "category": category(m["directory"]), "restarts": None,
                        "crashed": None, "timeouts": None, "random_gap": None, "standard_gap": None,
                        "standard_date": None, "widening": None, "passes": False,
                        "reasons": ["no result: " + (m.get("error") or "the run failed")]})
    return out


def demote(verdict):
    """Whether the verdict means the system must leave its category."""
    return verdict["category"] in ("production", "elite") and not verdict["passes"]
