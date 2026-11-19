#!/usr/bin/env python3
"""One long-lived chDB instance serving queries over a Unix socket.

./start runs this in the background. The process opens the database in
.clickbench once and keeps it open; every client connection is served by its
own thread with its own chDB Session, which it reuses for all queries sent
over that connection. ./query sends one query per connection, the concurrent
worker (./concurrent-worker) keeps its connection, and so its session, for the
whole QPS test.

The protocol is in client.py.
"""

import os
import signal
import socketserver
import struct
import sys
import time

from chdb.session import Session

SOCKET = os.environ.get("BENCH_CHDB_SOCKET", "chdb.sock")
DATA = ".clickbench"


def read_exactly(stream, size):
    data = stream.read(size)
    if data is None or len(data) != size:
        return None
    return data


class Request:
    def __init__(self, stream, sql):
        self.stream = stream
        self.sql = sql

    def send(self, status, elapsed, payload):
        payload = payload.encode("utf-8", "replace")
        self.stream.write(struct.pack(">BdQ", status, elapsed, len(payload)) + payload)
        self.stream.flush()

    def reply(self, output, elapsed):
        self.send(0, elapsed, output)

    def fail(self, message):
        self.send(1, 0.0, message)


def requests(rfile, wfile):
    """The requests of one connection, until the client closes it."""
    while True:
        header = read_exactly(rfile, 8)
        if header is None:
            return
        (size,) = struct.unpack(">Q", header)
        sql = read_exactly(rfile, size)
        if sql is None:
            return
        yield Request(wfile, sql.decode("utf-8"))


def worker(requests):
    session = Session(DATA)
    try:
        session.query("USE clickbench")
        for request in requests:
            started = time.perf_counter()
            try:
                output = str(session.query(request.sql, "Pretty"))
            except Exception as exc:
                request.fail(str(exc))
            else:
                request.reply(output, time.perf_counter() - started)
    finally:
        session.close()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            worker(requests(self.rfile, self.wfile))
        except (BrokenPipeError, ConnectionResetError):
            # The client went away (e.g. a query timeout in the driver).
            pass


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def main():
    # The instance: created once, alive until the process exits. The database
    # must exist before a connection's `USE clickbench` (./load creates the
    # table in it).
    instance = Session(DATA)
    instance.query("CREATE DATABASE IF NOT EXISTS clickbench ENGINE = Atomic")

    # A leftover socket of a killed server.
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    # Bind only after the instance is up: ./check succeeds once it can connect.
    server = Server(SOCKET, Handler)

    def terminate(signum, frame):
        os.unlink(SOCKET)
        # Don't wait for the connection threads: a running query can't be
        # interrupted from here. MergeTree keeps the loaded parts on disk.
        os._exit(0)

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    print(f"chdb server: listening on {SOCKET}", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
