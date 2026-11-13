"""The latest attempt of every system of a group.

A system can run several times in a group (a rerun after a fix of the
benchmark). Its latest attempt counts: the one launched last, by the time its
machine started (the time of its log minus the total time in it), not by the
time it finished: a run of an older version of the benchmark can finish after
a run of the newer one. If the latest attempt failed without a result (its log
has a non-zero exit status), the system has no result: the earlier result was
made by a benchmark that has been fixed since, and no longer stands for the
system.
"""

import datetime
import re

EXIT = re.compile(r"Exit status: (\d+), instance type: ([a-z0-9.-]+), total time: (\d+)s")
# A result and the log of the same machine arrive within this many seconds.
PAIRING = 600


def parse(t):
    return datetime.datetime.strptime(t[:19], "%Y-%m-%d %H:%M:%S")


def latest(results, logs):
    """results: [(time, result)], logs: [{"system", "content", "t"}]. Returns
    ({(machine, directory): result}, [failed log]) where a failed log is the
    latest attempt of its (machine, system)."""
    parsed = []
    for log in logs:
        m = EXIT.search(log["content"])
        if m:
            t = parse(log["t"])
            parsed.append((log, int(m.group(1)), m.group(2), t, t - datetime.timedelta(seconds=int(m.group(3)))))
    attempts = {}

    def offer(key, start, kind, value):
        if key not in attempts or attempts[key][0] <= start:
            attempts[key] = (start, kind, value)

    for t, r in results:
        t = parse(t)
        key = (r["machine"], r["directory"])
        # The start of the machine, from its log; without the log, the time of the result.
        paired = [p for p in parsed if p[1] == 0 and (p[2], p[0]["system"]) == key and abs((p[3] - t).total_seconds()) <= PAIRING]
        start = min(paired, key=lambda p: abs((p[3] - t).total_seconds()))[4] if paired else t
        offer(key, start, "result", r)
    for log, status, machine, _, start in parsed:
        if status != 0:
            offer((machine, log["system"]), start, "failed", log)
    ok = {k: v for k, (_, kind, v) in attempts.items() if kind == "result"}
    failed = [{**v, "machine": k[0]} for k, (_, kind, v) in attempts.items() if kind == "failed"]
    return ok, failed


def last_error(log):
    lines = [re.sub(r"\x1B\[[0-9;]*m", "", l).strip() for l in log.splitlines()]
    lines = [l for l in lines if l and not l.startswith("Exit status")]
    errors = [l for l in lines if re.match(r"^(ERROR|FATAL|PANIC|Error|error|Code: \d+|Traceback|Failed|random: \./check did not)", l)]
    mentions = [l for l in lines if re.search(r"(?i)(error|exception|fail|timeout|killed|denied|refus)", l)]
    return (errors or mentions or ["the run failed without a result"])[-1][:500]
