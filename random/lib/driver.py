#!/usr/bin/env python3
"""Runs the queries on a system concurrently and records every result.

Usage: driver.py --queries <translated queries.json> --output <dir>
                 [--parallel 4] [--repeats 3] [--timeout 600] [--seed <seed>]

Runs in the directory of the system and sends every query to its ./query
script (query text on stdin; the result on stdout; the timing on the last
numeric line of stderr; exit code 0 on success; the contract of ClickBench).

The dispatcher takes the list of queries, repeats it --repeats times, orders
the list pseudorandomly by a hash of the query id, the repeat number and the
seed (the same order on every system, because the ids are the same), and
hands every query to the next free worker, --parallel workers in total. There
are no cold and hot runs; the measure is the total time.

Results: <dir>/out/<id>.<repeat>.out is the output of the query, and
<dir>/run.json has the total time and, for every execution, the status
(ok, error, timeout, unsupported), the time measured by the driver, the time
reported by the system, and the start offset.

A watchdog polls ./check every 5 seconds; if the system is down, it is
restarted with ./start, and for an in-memory system (BENCH_DURABLE=no) ./load
runs again; the queries that fail meanwhile are errors.
"""

import argparse
import hashlib
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time

NUMBER = re.compile(r"^[0-9]+(\.[0-9]+)?$")


def reported_time(stderr):
    for line in reversed(stderr.replace("\r", "\n").splitlines()):
        if NUMBER.match(line.strip()):
            return float(line.strip())
    return None


def schedule(queries, repeats, seed):
    items = [(q, r) for q in queries for r in range(1, repeats + 1)]
    return sorted(items, key=lambda item: hashlib.sha256(f"{seed}/{item[0]['id']}/{item[1]}".encode()).hexdigest())


def run_one(sql, out_path, timeout):
    start = time.time()
    with open(out_path, "wb") as out:
        process = subprocess.Popen(["./query"], stdin=subprocess.PIPE, stdout=out, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            _, stderr = process.communicate(sql.encode(), timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            return "timeout", time.time() - start, None, ""
    elapsed = time.time() - start
    stderr = stderr.decode(errors="replace")
    reported = reported_time(stderr)
    if process.returncode != 0 or reported is None:
        return "error", elapsed, None, stderr[-2000:]
    return "ok", elapsed, reported, ""


CHECK_TIMEOUT = 60


def is_up():
    """./check succeeds within CHECK_TIMEOUT seconds. A check that hangs (a hung
    server keeps its port open, and a check with curl without --max-time waits
    forever) counts as down, with its process group killed."""
    process = subprocess.Popen(["./check"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        return process.wait(timeout=CHECK_TIMEOUT) == 0
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        return False


def watchdog(stop, restarts, up, dead):
    """Restarts the system when it is down: every 5 s, or at once when a worker
    finds it down after a failed query (up cleared). The workers wait while it
    is down (up), so the queries of the schedule don't fail one after another
    in the restart. A system that doesn't come back in 300 s is dead: the
    workers go on, and the rest of the queries fail without being sent."""
    while not stop.is_set():
        if up.is_set():
            stop.wait(5)
            if stop.is_set() or is_up():
                continue
            up.clear()
        restarts.append(time.time())
        print("driver: the system is down, restarting", file=sys.stderr)
        subprocess.run(["./stop"], capture_output=True)
        subprocess.run(["./start"], capture_output=True)
        for _ in range(300):
            if is_up():
                break
            time.sleep(1)
        else:
            print("driver: the system did not come back in 300 s", file=sys.stderr)
            dead.set()
            up.set()
            return
        # The data of an in-memory system is gone with the process.
        if os.environ.get("BENCH_DURABLE", "yes") != "yes":
            subprocess.run(["./load"], capture_output=True)
        up.set()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--queries", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--parallel", type=int, default=4)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--seed", default="")
    parser.add_argument("--no-watchdog", action="store_true")
    args = parser.parse_args()

    with open(args.queries) as f:
        queries = json.load(f)["queries"]
    out_dir = os.path.join(args.output, "out")
    os.makedirs(out_dir, exist_ok=True)

    executions = []
    lock = threading.Lock()
    work = queue.Queue()
    for q, r in schedule(queries, args.repeats, args.seed):
        work.put((q, r))

    start = time.time()

    def worker(n):
        while True:
            try:
                q, r = work.get_nowait()
            except queue.Empty:
                return
            up.wait()
            begin = time.time() - start
            if not q["sql"]:
                status, elapsed, reported, error = "unsupported", 0.0, None, "no translation"
            elif dead.is_set():
                status, elapsed, reported, error = "error", 0.0, None, "the system is down and did not come back"
            else:
                status, elapsed, reported, error = run_one(q["sql"], os.path.join(out_dir, f"{q['id']}.{r}.out"),
                                                           args.timeout)
                # The system went down in this query (it still counts as a
                # failure): the next queries wait for the restart.
                # Once the watchdog has given up (dead), nobody would set it back.
                if status != "ok" and watched and not dead.is_set() and not is_up():
                    up.clear()
                    if dead.is_set():
                        up.set()
            record = {"id": q["id"], "repeat": r, "worker": n, "status": status, "start": round(begin, 3),
                      "time": round(elapsed, 3), "reported_time": reported, "error": error}
            with lock:
                executions.append(record)
            print(f"driver: {q['id']}.{r} {status} {elapsed:.3f} s", file=sys.stderr)

    stop, restarts, up, dead = threading.Event(), [], threading.Event(), threading.Event()
    up.set()
    watched = not args.no_watchdog
    if watched:
        threading.Thread(target=watchdog, args=(stop, restarts, up, dead), daemon=True).start()
    threads = [threading.Thread(target=worker, args=(n,)) for n in range(args.parallel)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    total = time.time() - start
    stop.set()

    executions.sort(key=lambda e: e["start"])
    counts = {}
    for e in executions:
        counts[e["status"]] = counts.get(e["status"], 0) + 1
    with open(os.path.join(args.output, "run.json"), "w") as f:
        json.dump({"total_time": round(total, 3), "parallel": args.parallel, "repeats": args.repeats,
                   "timeout": args.timeout, "restarts": len(restarts), "counts": counts,
                   "executions": executions}, f, indent=1)
    print(f"Total time: {total:.3f}", file=sys.stderr)
    print(f"Statuses: {json.dumps(counts)}", file=sys.stderr)


if __name__ == "__main__":
    main()
