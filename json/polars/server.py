#!/usr/bin/env python3

"""
Long-lived Polars query server for JSONBench, modeled after ../../polars/server.py
and ../opteryx/server.py.

Standard library HTTP server + polars only.

Routes (127.0.0.1:8422):
    GET  /health -> 200, body = polars version (no query is run).
    POST /query  -> body = one Polars expression on `bluesky` (a fresh LazyFrame
                    scanning bluesky/*.parquet). Evaluates the expression and
                    renders the full untruncated result inside the timed window
                    (per ClickBench Output Suppression rules).
"""

import os
import timeit
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer

import polars as pl

pl.Config.set_engine_affinity("streaming")
pl.Config.set_tbl_rows(-1)
pl.Config.set_tbl_cols(-1)
pl.Config.set_tbl_width_chars(-1)
pl.Config.set_fmt_str_lengths(65535)

HOST = "127.0.0.1"
PORT = int(os.environ.get("BENCH_POLARS_PORT", "8422"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/health":
            self.send_error(404)
            return
        body = pl.__version__.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/query":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        code = self.rfile.read(length).decode("utf-8").strip()
        if not code:
            self.send_error(400, "empty query")
            return

        try:
            compiled = compile(code, "<query>", "eval")
            bluesky = pl.scan_parquet("bluesky/*.parquet")
            start = timeit.default_timer()
            value = eval(compiled, {"bluesky": bluesky, "pl": pl})
            rendered = str(value) if isinstance(value, (pl.DataFrame, pl.Series, pl.LazyFrame)) else repr(value)
            elapsed = timeit.default_timer() - start
        except Exception:
            traceback.print_exc()
            err = traceback.format_exc().encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Length", str(len(err)))
            self.end_headers()
            self.wfile.write(err)
            return

        body = (rendered + "\n").encode("utf-8") if not rendered.endswith("\n") else rendered.encode("utf-8")
        self.send_response(200)
        self.send_header("X-Elapsed", f"{elapsed:.6f}")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    HTTPServer((HOST, PORT), Handler).serve_forever()
