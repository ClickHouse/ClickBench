"""
Long-lived Opteryx query server for the JSONBench entry, adapted from the main
ClickBench entry (../../opteryx/server.py).

Standard library only: the venv holds opteryx-core and nothing else.

Routes (127.0.0.1:8421):
    GET  /health  -> 200, body = opteryx version. No query is run: ./check
                     calls this before every cold try.
    POST /query   -> body = one SQL statement, where {TABLE} stands for
                     READ_JSONL('<dir>/*.jsonl', ignore_errors => true) over
                     the files prepared by ./load. Response body = the result
                     as TSV; header X-Elapsed = seconds spent draining
                     execute_to_morsels (the span the original JSONBench PR
                     measured; interpreter start-up and rendering are outside).

ignore_errors skips the few records of the dataset that are not valid JSON
(split by a raw newline or holding a raw control character).

One session per request. There is no result cache: what carries over from
try 1 to tries 2-3 is the process state and the OS page cache.

A query that raises is not caught: the connection closes with no response,
./query exits non-zero and the driver records null. The traceback is in
server.log.
"""

import os
import timeit
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer

import opteryx

HOST = "127.0.0.1"
PORT = 8421
JSONL_DIR = os.environ["OPTERYX_JSONL_DIR"]
TABLE = f"READ_JSONL('{JSONL_DIR}/*.jsonl', ignore_errors => true)"


def render_tsv(morsels) -> bytes:
    lines = []
    for morsel in morsels:
        if not lines:
            lines.append("\t".join(c.decode() if isinstance(c, bytes) else str(c) for c in morsel.column_names))
        for i in range(morsel.num_rows):
            lines.append("\t".join("" if v is None else str(v) for v in morsel[i]))
    return ("\n".join(lines) + "\n").encode() if lines else b""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        body = opteryx.__version__.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/query":
            self.send_error(404)
            return
        query = self.rfile.read(int(self.headers["Content-Length"])).decode()
        query = query.replace("{TABLE}", TABLE).strip().rstrip(";")

        session = opteryx.session()
        start = timeit.default_timer()
        morsels = list(session.execute_to_morsels(query))
        elapsed = timeit.default_timer() - start

        body = render_tsv(morsels)
        session.close()

        self.send_response(200)
        self.send_header("X-Elapsed", f"{elapsed:.6f}")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    HTTPServer((HOST, PORT), Handler).serve_forever()
