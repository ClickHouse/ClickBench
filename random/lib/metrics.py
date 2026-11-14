"""The summary metrics of a group of the randomized benchmark.

Geometric mean of the relative times, as on the ClickBench page, but with the
average time of a query instead of its best one: the queries run concurrently
and in a random order, so the average smooths over what ran next to them and
over the first, colder runs.

  1. For every system and query: the average time of its executions (the
     repeats). A failed execution (a wrong result, an error, a timeout, a
     query the system can't express) counts as a penalty: 5 times the
     slowest correct execution of the query on any system of the group (as
     ClickBench counts a missing result as 2 times the slowest one).
  2. For every system and query: the ratio of that average to the best
     average among the systems, as (0.01 + average) / (0.01 + best) (the
     constant of ClickBench, so that very short queries don't dominate).
     Queries on which every system fails are skipped.
  3. For every system: the geometric mean of its ratios. 1 is the best
     possible; lower is better.

Penalized time: the total wall-clock time of all executions, plus the query
timeout for every failed execution, divided by the number of workers.
"""

import math

FAILED = ("wrong", "error", "timeout", "unsupported")
CONSTANT_TIME_ADD = 0.01
FAILURE_PENALTY = 5


def failure_times(results):
    """{query id: the time a failed execution counts as}: 5 x the slowest
    correct execution of the query among the results. A query without any
    correct execution has none."""
    worst = {}
    for r in results:
        for e in r["executions"]:
            if e["status"] not in FAILED:
                worst[e["id"]] = max(worst.get(e["id"], 0.0), e["time"])
    return {q: FAILURE_PENALTY * t for q, t in worst.items()}


def average_times(result, penalties):
    """{query id: average time of the executions, a failure counting as the penalty}."""
    per_query = {}
    for e in result["executions"]:
        if e["status"] in FAILED:
            if e["id"] not in penalties:
                continue  # every system failed: the query is skipped
            t = penalties[e["id"]]
        else:
            t = e["time"]
        per_query.setdefault(e["id"], []).append(t)
    return {q: sum(ts) / len(ts) for q, ts in per_query.items()}


def geomeans(results):
    """{directory: geomean} for results of one machine type."""
    penalties = failure_times(results)
    averages = {r["directory"]: average_times(r, penalties) for r in results}
    usable = sorted(penalties)
    out = {}
    for r in results:
        a = averages[r["directory"]]
        logs = []
        for q in usable:
            if q not in a:
                continue
            best = min(x[q] for x in averages.values() if q in x)
            logs.append(math.log((CONSTANT_TIME_ADD + a[q]) / (CONSTANT_TIME_ADD + best)))
        out[r["directory"]] = math.exp(sum(logs) / len(logs)) if logs else None
    return out


def penalized_time(result):
    failed = sum(result["counts"].get(s, 0) for s in FAILED)
    return result["total_time"] + failed * result["query_timeout"] / result["parallel"]
