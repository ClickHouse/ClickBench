"""
Long-lived Opteryx query server for the ClickBench entry.

Standard library only — the venv holds opteryx-core and nothing else.

Routes (127.0.0.1:8421):
    GET  /health  -> 200, body = opteryx version. No query is run: ./check
                     calls this before every cold try, and a query here would
                     warm the engine ahead of the measurement.
    POST /query   -> body = one SQL statement. Response body = the result as
                     TSV (header + rows); header X-Elapsed = seconds spent
                     draining execute_to_morsels.

The clock covers exactly what the embedded entry's clock covered: draining
`execute_to_morsels`. Session construction (warm: ~0.04ms) and TSV rendering
are outside it.

One session per request; the engine's footer and schema caches are process
scoped, so tries 2..3 of a query see a warm process. There is no result cache.

A query that raises is not caught: the handler dies, the connection closes with
no response, `./query` exits non-zero and the driver records null. The traceback
is in server.log.
"""

import timeit
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer

import opteryx

HOST = "127.0.0.1"
PORT = 8421


def render_tsv(morsels) -> bytes:
    lines = []
    for morsel in morsels:
        if not lines:
            lines.append("\t".join(c.decode() for c in morsel.column_names))
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
