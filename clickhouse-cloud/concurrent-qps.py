#!/usr/bin/env python3
# The concurrent QPS test, as `bench_concurrent_qps` in lib/benchmark-common.sh:
# N connections, each running the queries in its own seeded order until the deadline;
# QPS = successful queries / duration.
#
# The shell version starts several processes and a new TLS connection for every query.
# All services are benchmarked at the same time from a single runner, and that overhead
# made the runner the bottleneck. This one runs the connections as threads in one process,
# and every connection keeps its HTTPS connection open between queries.
#
# Usage: FQDN=... PASSWORD=... ./concurrent-qps.py [queries.sql]

import base64
import hashlib
import http.client
import os
import random
import sys
import threading
import time
import urllib.parse

connections = int(os.environ.get("BENCH_CONCURRENT_CONNECTIONS", "10"))
duration = int(os.environ.get("BENCH_CONCURRENT_DURATION", "600"))
seed = os.environ.get("BENCH_CONCURRENT_SEED", "clickbench")
host = os.environ["FQDN"]
auth = "Basic " + base64.b64encode(f"default:{os.environ.get('PASSWORD', '')}".encode()).decode()

with open(sys.argv[1] if len(sys.argv) > 1 else "queries.sql") as f:
    queries = [line.rstrip("\n") for line in f if line.strip()]

# `wait_end_of_query` makes an exception in the middle of the query result in an HTTP error code.
path = "/?" + urllib.parse.urlencode({"default_format": "Null", "wait_end_of_query": "1"})


def permutation(conn):
    # The same order as in lib/benchmark-common.sh, so the numbers are comparable across systems.
    seed_int = int.from_bytes(hashlib.sha256(f"{seed}-{conn}".encode()).digest()[:8], "big")
    xs = list(range(len(queries)))
    random.Random(seed_int).shuffle(xs)
    return xs


stats = {}


def worker(conn, deadline):
    perm = permutation(conn)
    ok = err = idx = 0
    c = None
    while time.time() < deadline:
        query = queries[perm[idx]]
        idx = (idx + 1) % len(perm)
        try:
            if c is None:
                c = http.client.HTTPSConnection(host, 8443, timeout=duration)
            c.request("POST", path, body=query.encode(), headers={"Authorization": auth})
            response = c.getresponse()
            response.read()
            if response.status == 200:
                ok += 1
            else:
                err += 1
        except Exception:
            err += 1
            if c is not None:
                c.close()
            c = None
    if c is not None:
        c.close()
    stats[conn] = (ok, err)


deadline = time.time() + duration
threads = [threading.Thread(target=worker, args=(conn, deadline)) for conn in range(1, connections + 1)]
for t in threads:
    t.start()
for t in threads:
    t.join()

total_ok = sum(ok for ok, _ in stats.values())
total = sum(ok + err for ok, err in stats.values())
print("Concurrent QPS: " + (f"{total_ok / duration:.3f}" if total_ok else "null"))
print("Concurrent error ratio: " + (f"{(total - total_ok) / total:.3f}" if total else "null"))
