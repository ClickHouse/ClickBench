"""The latest attempt of every system of a group.

A system can run several times in a group (a rerun after a fix of the
benchmark). Its latest attempt counts: the latest result, unless a run that
failed without a result (its log has a non-zero exit status) came after it.
Then the system has no result: the earlier result was made by a benchmark
that has been fixed since, and it no longer stands for the system.
"""

import re

EXIT = re.compile(r"Exit status: (\d+), instance type: ([a-z0-9.-]+),")


def latest(results, logs):
    """results: [(time, result)], logs: [{"system", "content", "t"}], both in
    the order of time. Returns ({(machine, directory): result}, [failed log])
    where a failed log is the latest attempt of its (machine, system)."""
    attempts = {}
    for t, r in results:
        attempts[(r["machine"], r["directory"])] = (t, "result", r)
    for log in logs:
        m = EXIT.search(log["content"])
        if not m or m.group(1) == "0":
            continue
        key = (m.group(2), log["system"])
        if key not in attempts or attempts[key][0] < log["t"]:
            attempts[key] = (log["t"], "failed", log)
    ok = {k: v for k, (_, kind, v) in attempts.items() if kind == "result"}
    failed = [{**v, "machine": k[0]} for k, (_, kind, v) in attempts.items() if kind == "failed"]
    return ok, failed


def last_error(log):
    lines = [re.sub(r"\x1B\[[0-9;]*m", "", l).strip() for l in log.splitlines()]
    lines = [l for l in lines if l and not l.startswith("Exit status")]
    errors = [l for l in lines if re.match(r"^(ERROR|FATAL|PANIC|Error|error|Code: \d+|Traceback|Failed|random: \./check did not)", l)]
    mentions = [l for l in lines if re.search(r"(?i)(error|exception|fail|timeout|killed|denied|refus)", l)]
    return (errors or mentions or ["the run failed without a result"])[-1][:500]
