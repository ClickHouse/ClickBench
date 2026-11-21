#!/usr/bin/env python3
"""Client of server.py. Only the standard library: it doesn't load chDB.

    client.py                  Sends the query on stdin. Stdout: the result.
                               Stderr: the time measured by the server, in
                               fractional seconds. Exit code 1 on an error.
    client.py --worker DEADLINE
                               The concurrent QPS test worker: cycles through
                               the queries on stdin (one per line) on one
                               connection, so in one server session, until
                               DEADLINE (Unix seconds), then prints
                               "<successful> <failed>".

Protocol: the client sends a query as an 8-byte big-endian length and the
UTF-8 text; the server answers with a status byte (0 success, 1 error), the
elapsed time as a big-endian double, an 8-byte length, and the result or the
error message. A connection carries any number of queries, one at a time.
"""

import os
import socket
import struct
import sys
import time

SOCKET = os.environ.get("BENCH_CHDB_SOCKET", "chdb.sock")


def connect():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET)
    return sock


def read_exactly(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ConnectionError("the server closed the connection")
    return data


def run(stream, sql):
    data = sql.encode("utf-8")
    stream.write(struct.pack(">Q", len(data)) + data)
    stream.flush()
    status, elapsed, size = struct.unpack(">BdQ", read_exactly(stream, 17))
    return status, elapsed, read_exactly(stream, size).decode("utf-8", "replace")


def query():
    sql = sys.stdin.read()
    with connect() as sock, sock.makefile("rwb") as stream:
        status, elapsed, payload = run(stream, sql)
    if status != 0:
        print(payload, file=sys.stderr)
        sys.exit(1)
    if payload:
        sys.stdout.write(payload if payload.endswith("\n") else payload + "\n")
        sys.stdout.flush()
    print(f"{elapsed:.3f}", file=sys.stderr)


def concurrent_worker(deadline):
    queries = [q for q in sys.stdin.read().splitlines() if q.strip()]
    ok = err = i = 0
    sock = stream = None
    while time.time() < deadline:
        if stream is None:
            # The first connection, or the server went down and the driver's
            # watchdog is restarting it: wait until it accepts connections.
            try:
                sock = connect()
            except OSError:
                time.sleep(1)
                continue
            stream = sock.makefile("rwb")
        try:
            status, _, payload = run(stream, queries[i])
        except OSError as exc:
            status, payload = 1, f"connection lost: {exc}"
            stream.close()
            sock.close()
            sock = stream = None
        if status == 0:
            ok += 1
        else:
            err += 1
            print(f"concurrent-worker: {payload}", file=sys.stderr)
        i = (i + 1) % len(queries)
    if stream is not None:
        stream.close()
        sock.close()
    print(ok, err)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        concurrent_worker(float(sys.argv[2]))
    else:
        query()
