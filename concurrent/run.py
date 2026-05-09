#!/usr/bin/env python3
"""Concurrent ClickBench driver.

Spawns --concurrency persistent connections; each picks a uniformly random
query from queries.sql and executes it in a loop for --duration seconds.
Reports total queries, QPS, and latency percentiles. Backends:

  clickhouse  -- native HTTP (port 8123), uses stdlib http.client
  starrocks   -- MySQL wire protocol (port 9030), uses pymysql

The first --warmup seconds are excluded from the measurement window so
results reflect a steady state rather than connection ramp-up.
"""

import argparse
import json
import random
import statistics
import sys
import threading
import time
from collections import defaultdict
from urllib.parse import urlencode


def parse_args():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--backend", required=True, choices=["clickhouse", "starrocks"])
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=None,
                   help="default 8123 (clickhouse) / 9030 (starrocks)")
    p.add_argument("--user", default=None,
                   help="default 'default' (clickhouse) / 'root' (starrocks)")
    p.add_argument("--password", default="")
    p.add_argument("--database", default=None,
                   help="default 'default' (clickhouse) / 'hits' (starrocks)")
    p.add_argument("--queries", default="queries.sql")
    p.add_argument("--concurrency", type=int, default=10)
    p.add_argument("--duration", type=int, default=600,
                   help="measurement window in seconds (default 600 = 10 min)")
    p.add_argument("--warmup", type=int, default=30,
                   help="warmup seconds excluded from the measurement window")
    p.add_argument("--query-timeout", type=int, default=120,
                   help="per-query timeout in seconds")
    p.add_argument("--seed", type=int, default=42,
                   help="base seed; each worker uses seed+worker_id")
    p.add_argument("--report-interval", type=int, default=30,
                   help="progress line interval in seconds")
    p.add_argument("--output-json", default=None,
                   help="write the final summary to this JSON file")
    return p.parse_args()


def load_queries(path):
    with open(path) as f:
        return [line.rstrip("\n") for line in f if line.strip()]


class ClickHouseConn:
    def __init__(self, host, port, user, password, database, timeout):
        import http.client
        self._http = http.client
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.timeout = timeout
        params = {"database": database, "default_format": "TabSeparated"}
        if user:
            params["user"] = user
        if password:
            params["password"] = password
        self.path = "/?" + urlencode(params)
        self.conn = None
        self._connect()

    def _connect(self):
        self.conn = self._http.HTTPConnection(self.host, self.port, timeout=self.timeout)

    def execute(self, query):
        try:
            self.conn.request("POST", self.path, body=query.encode("utf-8"))
            resp = self.conn.getresponse()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
            if resp.status != 200:
                self.close()
                self._connect()
                return False
            return True
        except Exception:
            self.close()
            try:
                self._connect()
            except Exception:
                pass
            return False

    def close(self):
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:
            pass


class StarRocksConn:
    def __init__(self, host, port, user, password, database, timeout):
        try:
            import pymysql
        except ImportError:
            sys.exit("pymysql is required for the starrocks backend: pip install pymysql")
        self._pymysql = pymysql
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.timeout = timeout
        self.conn = None
        self._connect()

    def _connect(self):
        self.conn = self._pymysql.connect(
            host=self.host, port=self.port,
            user=self.user, password=self.password, database=self.database,
            connect_timeout=self.timeout,
            read_timeout=self.timeout, write_timeout=self.timeout,
            autocommit=True,
        )

    def execute(self, query):
        try:
            with self.conn.cursor() as cur:
                cur.execute(query)
                while True:
                    rows = cur.fetchmany(10000)
                    if not rows:
                        break
            return True
        except Exception:
            self.close()
            try:
                self._connect()
            except Exception:
                pass
            return False

    def close(self):
        try:
            if self.conn is not None:
                self.conn.close()
        except Exception:
            pass


def make_connection(args):
    if args.backend == "clickhouse":
        return ClickHouseConn(
            args.host, args.port or 8123,
            args.user or "default", args.password,
            args.database or "default", args.query_timeout,
        )
    return StarRocksConn(
        args.host, args.port or 9030,
        args.user or "root", args.password,
        args.database or "hits", args.query_timeout,
    )


def worker(args, queries, stop_event, warmup_until, results, results_lock,
           live_ok, live_err, worker_id):
    rng = random.Random((args.seed or 0) * 1000003 + worker_id)
    try:
        conn = make_connection(args)
    except Exception as e:
        with results_lock:
            results["connect_errors"].append(f"worker {worker_id}: {e}")
        return

    local_lat = []
    local_idx = []
    local_ok = 0
    local_err = 0
    while not stop_event.is_set():
        idx = rng.randrange(len(queries))
        q = queries[idx]
        t0 = time.perf_counter()
        ok = conn.execute(q)
        t1 = time.perf_counter()
        if t0 < warmup_until:
            continue
        if ok:
            local_lat.append(t1 - t0)
            local_idx.append(idx)
            local_ok += 1
            live_ok[worker_id] = local_ok
        else:
            local_err += 1
            live_err[worker_id] = local_err
    conn.close()

    with results_lock:
        results["latencies"].extend(local_lat)
        results["query_idx"].extend(local_idx)
        results["ok"] += local_ok
        results["err"] += local_err


def percentile(sorted_data, p):
    if not sorted_data:
        return float("nan")
    k = (len(sorted_data) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_data) - 1)
    if f == c:
        return sorted_data[f]
    return sorted_data[f] + (sorted_data[c] - sorted_data[f]) * (k - f)


def main():
    args = parse_args()
    queries = load_queries(args.queries)
    if not queries:
        sys.exit(f"No queries loaded from {args.queries}")

    print(f"Loaded {len(queries)} queries from {args.queries}", file=sys.stderr)
    print(f"Backend: {args.backend}  concurrency: {args.concurrency}  "
          f"warmup: {args.warmup}s  duration: {args.duration}s",
          file=sys.stderr)

    stop_event = threading.Event()
    warmup_until = time.perf_counter() + args.warmup
    results = {"latencies": [], "query_idx": [], "ok": 0, "err": 0,
               "connect_errors": []}
    results_lock = threading.Lock()
    # Per-worker live counters (one slot each, no contention).
    live_ok = [0] * args.concurrency
    live_err = [0] * args.concurrency

    threads = []
    for i in range(args.concurrency):
        t = threading.Thread(
            target=worker,
            args=(args, queries, stop_event, warmup_until, results, results_lock,
                  live_ok, live_err, i),
            daemon=True,
        )
        t.start()
        threads.append(t)

    deadline = warmup_until + args.duration
    last_report = time.perf_counter()
    while True:
        now = time.perf_counter()
        if now >= deadline:
            break
        time.sleep(min(1.0, deadline - now))
        now = time.perf_counter()
        if now - last_report >= args.report_interval:
            ok = sum(live_ok); err = sum(live_err)
            elapsed_meas = max(0.0, now - warmup_until)
            qps = ok / elapsed_meas if elapsed_meas > 0 else 0.0
            phase = "warmup" if now < warmup_until else "measure"
            print(f"  [{phase} t={now - warmup_until + args.warmup:6.0f}s] "
                  f"ok={ok} err={err} qps={qps:.1f}", file=sys.stderr)
            last_report = now

    stop_event.set()
    for t in threads:
        t.join()

    lats = sorted(results["latencies"])
    ok = results["ok"]; err = results["err"]
    qps = ok / args.duration

    print()
    print(f"=== {args.backend}  concurrency={args.concurrency}  duration={args.duration}s ===")
    print(f"completed:    {ok}")
    print(f"errors:       {err}")
    print(f"QPS:          {qps:.2f}")
    if results["connect_errors"]:
        print(f"connect errors: {len(results['connect_errors'])}")
        for msg in results["connect_errors"][:5]:
            print(f"  {msg}")
    if lats:
        print(f"latency mean: {statistics.fmean(lats) * 1000:.1f} ms")
        print(f"latency p50:  {percentile(lats, 0.50) * 1000:.1f} ms")
        print(f"latency p95:  {percentile(lats, 0.95) * 1000:.1f} ms")
        print(f"latency p99:  {percentile(lats, 0.99) * 1000:.1f} ms")
        print(f"latency max:  {lats[-1] * 1000:.1f} ms")

    counts = defaultdict(int)
    sums = defaultdict(float)
    for idx, lat in zip(results["query_idx"], results["latencies"]):
        counts[idx] += 1
        sums[idx] += lat

    print()
    print("per-query (1-based index, count, mean ms):")
    for idx in sorted(counts):
        c = counts[idx]
        m = sums[idx] / c
        print(f"  Q{idx + 1:02d}: n={c:6d}  mean={m * 1000:8.1f} ms")

    if args.output_json:
        summary = {
            "backend": args.backend,
            "host": args.host,
            "concurrency": args.concurrency,
            "duration_sec": args.duration,
            "warmup_sec": args.warmup,
            "queries_file": args.queries,
            "completed": ok,
            "errors": err,
            "qps": qps,
            "latency_ms": {
                "mean": statistics.fmean(lats) * 1000 if lats else None,
                "p50": percentile(lats, 0.50) * 1000 if lats else None,
                "p95": percentile(lats, 0.95) * 1000 if lats else None,
                "p99": percentile(lats, 0.99) * 1000 if lats else None,
                "max": lats[-1] * 1000 if lats else None,
            },
            "per_query": {
                str(idx + 1): {"count": counts[idx], "mean_ms": sums[idx] / counts[idx] * 1000}
                for idx in sorted(counts)
            },
        }
        with open(args.output_json, "w") as f:
            json.dump(summary, f, indent=2)


if __name__ == "__main__":
    main()
