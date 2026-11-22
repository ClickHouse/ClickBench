#!/usr/bin/env python3
"""ClickBench wrapper around SynnoDB's DuckDB drop-in connection.

SynnoDB is used the way its documentation describes: `synnodb.connect(...)` opens a DuckDB
database and routes every statement that matches a published bespoke engine to that engine,
falling back to DuckDB for everything else. One long-lived process holds the connection, so the
engine's in-memory copy of the data survives between queries, as it would in an application.

Routes (HTTP over the Unix socket synnodb.sock):
    GET  /health     -> 200 once the server is up.
    POST /load       -> builds hits.db from hits.parquet, loads the engine, verifies every
                        benchmark query on it against DuckDB. Returns {"elapsed": seconds, ...}.
    POST /query      -> body: SQL text. Returns {"elapsed": seconds, "served_by": ...}.
    GET  /data-size  -> {"bytes": size of hits.db}.

Whether the engine may serve a query is decided once, in /load: every query the engine has an
implementation for runs on the engine and on DuckDB, and the two results are compared with the
comparison SynnoDB's factory validates an engine with (see `engine_matches_duckdb`). The outcome
is stored in verified.json. A query whose engine answer was rejected is not sent to the router in
the timed runs; DuckDB answers it. The router itself runs with `cross_check_rate=0.0`, that is,
it does not execute the routed statements on DuckDB a second time.
"""

import json
import os
import socketserver
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

import duckdb
import synnodb
from synnodb.router import RouterMode, RouterPolicy
from synnodb.router.adapt import candidate_superset, results_equal
from synnodb.router.normalize import (
    has_order_by,
    order_by_key_indices,
    top_level_limit_offset,
    widened_query,
)
from synnodb.utils.sql_utils import extract_order_by_columns

HERE = Path(__file__).resolve().parent
DB = HERE / "hits.db"
PARQUET = HERE / "hits.parquet"
ENGINES = HERE / "engines"
VERIFIED = HERE / "verified.json"
SOCKET = HERE / "synnodb.sock"
QUERIES = [q.strip() for q in (HERE / "queries.sql").read_text().splitlines() if q.strip()]

# The engine keeps its own copy of the table in memory, next to the Arrow image in /dev/shm it is
# loaded from, so DuckDB cannot have its default 80% of the RAM.
DUCKDB_MEMORY_FRACTION = float(os.environ.get("BENCH_SYNNODB_DUCKDB_MEMORY_FRACTION", "0.2"))

LOCK = threading.Lock()
con = None  # the SynnoDB connection; None until hits.db is loaded and verified
rejected = set()  # statements whose engine answer differed from DuckDB's in /load


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


def normalize(sql):
    return sql.strip().rstrip(";").strip()


def duckdb_memory_limit():
    total = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    return f"{int(total * DUCKDB_MEMORY_FRACTION / 2**20)}MiB"


def open_connection():
    """Open hits.db behind the SynnoDB router.

    The number of threads is not set. DuckDB then uses all cores, and SynnoDB runs the engine
    with the number of threads recorded in its manifest: the one it was generated and validated
    with. An engine may keep per-thread structures, so another number is a configuration the
    factory has never checked."""
    return synnodb.connect(
        str(DB),
        read_only=True,
        config={"memory_limit": duckdb_memory_limit()},
        engines=str(ENGINES),
        policy=RouterPolicy(mode=RouterMode.SAMPLED, cross_check_rate=0.0, verbose=False),
    )


def use_verified():
    global rejected
    outcome = json.loads(VERIFIED.read_text())
    rejected = {normalize(QUERIES[n - 1]) for n in outcome["rejected"]}
    log(
        f"{DB.name}: the engine serves {len(outcome['engine'])} of {len(QUERIES)} queries,"
        f" {len(outcome['rejected'])} rejected, {len(outcome['no_engine'])} without an engine"
    )


def build_database():
    """The same table and the same conversion of the integer-encoded dates and timestamps as in
    ../duckdb/load."""
    for stale in (DB, Path(str(DB) + ".wal")):
        stale.unlink(missing_ok=True)
    plain = duckdb.connect(str(DB), config={"storage_compatibility_version": "latest"})
    plain.execute((HERE / "create.sql").read_text())
    plain.execute(
        """
        INSERT INTO hits
        SELECT * REPLACE (
            make_date(EventDate) AS EventDate,
            epoch_ms(EventTime * 1000) AS EventTime,
            epoch_ms(ClientEventTime * 1000) AS ClientEventTime,
            epoch_ms(LocalEventTime * 1000) AS LocalEventTime)
        FROM read_parquet(?, binary_as_string=True)
        """,
        [str(PARQUET)],
    )
    rows = plain.execute("SELECT count(*) FROM hits").fetchone()[0]
    plain.close()
    return rows


def sort_key_columns(sql, names):
    """The positions of the `ORDER BY` keys among the result columns, or None if a key is not a
    result column (the comparison is then strictly positional). As in the factory's validator,
    `ORDER BY COUNT(*)` refers to the column DuckDB names `count_star()`."""
    keys = order_by_key_indices(sql, names)
    if keys is None:
        columns = [
            "count_star()" if column.lower() == "count(*)" else column
            for column, _ in extract_order_by_columns(sql)
        ]
        if columns and all(column in names for column in columns):
            keys = [names.index(column) for column in columns]
    return keys


def engine_matches_duckdb(conn, sql):
    """Run the statement on the engine and on DuckDB and compare the results the way SynnoDB's
    factory does when it validates an engine (synnodb/tools/validate/run_and_check_queries.py):
    `results_equal`, which for `ORDER BY` requires the same sequence of sort keys and the same
    rows, and, for a `LIMIT` that cuts through rows tied on the sort keys, `candidate_superset`:
    DuckDB re-runs the query with a larger `LIMIT` until the group of tied rows is complete, and
    the engine's rows must be members of it. Which of the tied rows are returned is not defined
    by SQL, and DuckDB's own choice differs from run to run.

    SynnoDB's router has a cross-check too (`cross_check_rate`), but it compares without the
    second step and so rejects correct answers to such queries."""
    engine = conn.execute(sql).to_arrow_table()
    if (conn._last or {}).get("served_by") != "engine":
        return False  # the engine failed and SynnoDB fell back to DuckDB
    reference = conn.duckdb.execute(sql).to_arrow_table()

    ordered = has_order_by(sql)
    order_keys = sort_key_columns(sql, reference.column_names) if ordered else None
    row_limit, row_offset = top_level_limit_offset(sql)
    candidates = None
    if ordered and order_keys and row_limit is not None:

        def fetch_widened(limit):
            widened = widened_query(sql, limit)
            return None if widened is None else conn.duckdb.execute(widened).to_arrow_table()

        candidates = candidate_superset(
            reference,
            order_keys=order_keys,
            row_limit=row_limit,
            row_offset=row_offset,
            fetch_widened=fetch_widened,
        )
    return results_equal(
        engine,
        reference,
        ordered=ordered,
        order_keys=order_keys,
        row_limit=row_limit,
        candidates=candidates,
    )


def verify_engine(conn):
    """Returns three lists of query numbers: answered by the engine in agreement with DuckDB;
    having an engine implementation whose answer was rejected; having none."""
    conn.refresh_engines()
    templates = conn.router_stats()["registry"]["templates"]
    if templates == 0:
        raise RuntimeError(
            "no SynnoDB engine was registered for hits.db. The engine is loaded through "
            "/dev/shm, which must have room for the whole table as Arrow (about 67 GiB); "
            "see README.md"
        )
    if conn.synno_ingest_data() == 0:
        raise RuntimeError("the SynnoDB engine failed to load the data")
    log(f"engine loaded: {templates} statements registered")

    engine, engine_rejected, no_engine = [], [], []
    for number, sql in enumerate(QUERIES, 1):
        if conn.why(sql)["decision"] != "would-route":
            no_engine.append(number)
            continue
        try:
            ok = engine_matches_duckdb(conn, sql)
        except Exception as e:
            log(f"query {number}: the comparison failed: {e!r}")
            ok = False
        (engine if ok else engine_rejected).append(number)
    return engine, engine_rejected, no_engine


def do_load():
    global con
    start = time.perf_counter()
    if con is not None:
        con.close()
        con = None
    VERIFIED.unlink(missing_ok=True)

    rows = build_database()
    t_db = time.perf_counter()
    log(f"hits.db built: {rows} rows in {t_db - start:.1f} s")

    conn = open_connection()
    try:
        engine, engine_rejected, no_engine = verify_engine(conn)
    except BaseException:
        conn.close()
        raise
    t_verify = time.perf_counter()
    log(
        f"verified in {t_verify - t_db:.1f} s: engine {engine}, rejected {engine_rejected},"
        f" no engine {no_engine}"
    )
    if not engine:
        conn.close()
        raise RuntimeError("the SynnoDB engine did not answer any query in agreement with DuckDB")
    VERIFIED.write_text(
        json.dumps({"engine": engine, "rejected": engine_rejected, "no_engine": no_engine})
    )
    use_verified()
    con = conn
    return {
        "elapsed": round(time.perf_counter() - start, 3),
        "rows": rows,
        "database_seconds": round(t_db - start, 3),
        "verification_seconds": round(t_verify - t_db, 3),
        "engine": engine,
        "rejected": engine_rejected,
        "no_engine": no_engine,
    }


def do_query(sql):
    if con is None:
        raise LookupError("hits.db is not loaded; POST /load first")
    result = {}
    start = time.perf_counter()
    if normalize(sql) in rejected:
        rows = con.duckdb.execute(sql).fetchall()
        result["served_by"] = "duckdb"
    else:
        # The drop-in path. The router sends the statement to the engine if there is one for it;
        # otherwise, or if the engine fails, SynnoDB itself falls back to DuckDB.
        rows = con.execute(sql).fetchall()
        last = con._last or {}
        result["served_by"] = last.get("served_by", "duckdb")
        if last.get("engine_ms") is not None:
            # The time inside the engine, for the log only. The reported time is the wall-clock
            # time of the statement, which also has the routing and the transfer of the result.
            result["engine_ms"] = round(last["engine_ms"], 3)
    result["elapsed"] = round(time.perf_counter() - start, 3)
    result["rows"] = len(rows)
    return result


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def address_string(self):
        return "unix"

    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(200, {"ok": True, "loaded": con is not None})
        elif self.path == "/data-size":
            self.reply(200, {"bytes": DB.stat().st_size if DB.exists() else 0})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        try:
            with LOCK:
                if self.path == "/load":
                    self.reply(200, do_load())
                elif self.path == "/query":
                    self.reply(200, do_query(body))
                else:
                    self.reply(404, {"error": "not found"})
        except LookupError as e:
            self.reply(409, {"error": str(e)})
        except Exception as e:  # reported to ./load or ./query, which exit non-zero
            log(f"{self.path} failed: {e!r}")
            self.reply(500, {"error": repr(e)})


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == "__main__":
    SOCKET.unlink(missing_ok=True)
    if DB.exists() and VERIFIED.exists():
        use_verified()
        con = open_connection()
    server = Server(str(SOCKET), Handler)
    log(f"listening on {SOCKET}")
    server.serve_forever()
