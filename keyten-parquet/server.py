#!/usr/bin/env python3
"""Loopback-only dataframe benchmark server; queries are trusted Python expressions."""

import json
import os
import threading
from datetime import date as pydate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import keyten as kt

STORE = Path(os.environ.get("KEYTEN_NATIVE", "hits.k10dir"))
PARQUET = os.environ.get("KEYTEN_PARQUET")
PORT = int(os.environ.get("BENCH_KEYTEN_PORT", "8000"))
EPOCH = pydate(1970, 1, 1)
hits = None
open_lock = threading.Lock()


def date(y, m, d):
    return kt.lit((pydate(y, m, d) - EPOCH).days)


def minute(name):
    t = kt.col(name)
    return ((t % 3600 - t % 60) / 60).cast("int")


def minute_trunc(name):
    t = kt.col(name)
    return t - t % 60


def domain(name):
    value = kt.col(name)
    extracted = value.str_extract(r"^https?://(?:www\.)?([^/]+)/.*$")
    return kt.if_else(extracted.is_not_null(), extracted, value)


def execute(code):
    global hits
    # Opening belongs to the first timed request, so health checks cannot
    # populate source metadata or data caches before a cold query.
    if hits is None:
        with open_lock:
            if hits is None:
                hits = kt.scan_parquet(PARQUET) if PARQUET else kt.scan_native(str(STORE))
    result = eval(compile(code, "<query>", "eval"), {
        "kt": kt, "hits": hits, "date": date,
        "minute": minute, "minute_trunc": minute_trunc, "domain": domain,
    })
    # Complete column values, including every row and string, cross the wire.
    # Never use the dataframe's abbreviated display representation.
    return result.to_dict()


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, value):
        body = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.respond(200, {"ok": True, "version": kt.__version__})
        else:
            self.respond(404, {"error": "unknown route"})

    def do_POST(self):
        if self.path != "/query":
            self.respond(404, {"error": "unknown route"})
            return
        try:
            code = self.rfile.read(int(self.headers["Content-Length"])).decode()
            result = execute(code)
            self.respond(200, result)
        except Exception as error:
            self.respond(500, {"error": f"{type(error).__name__}: {error}"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
