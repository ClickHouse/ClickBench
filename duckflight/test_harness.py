"""Real-client ClickBench contract tests; run after ./install in this directory.

uv run --project . --frozen python test_harness.py
"""

from __future__ import annotations

import csv
import hashlib
import http.server
import importlib.util
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

import pyarrow.csv as arrow_csv

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("clickbench", ROOT / "harness.py")
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)


class ClickBenchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="duckflight-clickbench-")
        cls.state = Path(cls.directory.name)
        shutil.copy2(ROOT / ".state/duckdb", cls.state / "duckdb")
        shutil.copyfile(
            ROOT / ".state/duckflight.duckdb_extension",
            cls.state / "duckflight.duckdb_extension",
        )
        cls.queries = (ROOT / "queries.sql").read_text().splitlines()
        with harness.local_database(cls.state) as database:
            database.execute((ROOT / "create.sql").read_text())
            columns = database.execute("describe hits").fetchall()
            expressions = []
            # Seven distinct rows with unequal frequencies avoid LIMIT-boundary
            # ties; the full dataset still needs its own correctness validation.
            for name, kind, *_ in columns:
                if kind == "DATE":
                    value = "date '2013-07-14' + k::integer"
                elif kind == "TIMESTAMP":
                    value = "timestamp '2013-07-14' + k * interval '1 minute'"
                elif kind == "VARCHAR":
                    value = "'Google https://google.test/query-' || k"
                elif name == "CounterID":
                    value = "62"
                elif name in ("IsRefresh", "DontCountHits", "IsDownload"):
                    value = "0"
                else:
                    value = "k"
                expressions.append(f'{value} as "{name}"')
            database.execute(
                "insert into hits select "
                + ", ".join(expressions)
                + " from range(7) keys(k), lateral range((k + 1) * 101) copies(i)"
            )
            cls.expected = [database.execute(sql).fetchall() for sql in cls.queries]
            cls.expected_schemas = [
                database.sql(sql).to_arrow_table().schema for sql in cls.queries
            ]
        # URL-safe generated passwords can begin with a CLI option prefix.
        password = "-A-clickbench-test-password"
        salt = b"0123456789abcdef"
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 10000).hex()
        (cls.state / "password").write_text(password)
        (cls.state / "password").chmod(0o600)
        (cls.state / "auth.toml").write_text(
            f'[users.clickbench]\npassword_hash = "{digest}"\nsalt = {list(salt)}\niterations = 10000\n'
        )
        (cls.state / "auth.toml").chmod(0o600)
        result = cls.hook("start")
        if result.returncode:
            log = cls.state / "server.log"
            raise RuntimeError(
                result.stderr + (log.read_text() if log.exists() else "")
            )

    @classmethod
    def tearDownClass(cls):
        cls.hook("stop")
        cls.directory.cleanup()

    @classmethod
    def hook(cls, name, sql=""):
        return subprocess.run(
            [str(ROOT / name)],
            input=sql,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "DUCKFLIGHT_BENCH_STATE": str(cls.state),
                "DUCKFLIGHT_BENCH_CSV_NULL": "\\N",
            },
            timeout=150,
            check=False,
        )

    def test_all_43_queries_match_direct_duckdb(self):
        self.assertEqual(len(self.queries), 43)
        with harness.connect(self.state) as connection, connection.cursor() as cursor:
            for number, (sql, expected) in enumerate(
                zip(self.queries, self.expected), 1
            ):
                with self.subTest(query=number):
                    cursor.execute(sql)
                    self.assertEqual(Counter(cursor.fetchall()), Counter(expected))

    def test_direct_flight_execution_matches_all_43_queries(self):
        with harness.connect(self.state) as connection:
            for number, (sql, expected) in enumerate(
                zip(self.queries, self.expected), 1
            ):
                with self.subTest(query=number):
                    with harness.query_result(connection, sql) as table:
                        rows = list(
                            zip(*(column.to_pylist() for column in table.columns))
                        )
                    self.assertEqual(Counter(rows), Counter(expected))

    def test_query_hook_emits_complete_result_and_seconds(self):
        result = self.hook("query", "select i from range(10001) t(i) order by i")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["i", *map(str, range(10001))])
        self.assertGreater(float(result.stderr.strip()), 0)

    def test_query_hook_matches_all_43_queries(self):
        for number, (sql, expected, schema) in enumerate(
            zip(self.queries, self.expected, self.expected_schemas), 1
        ):
            with self.subTest(query=number):
                result = self.hook("query", sql)
                self.assertEqual(result.returncode, 0, result.stderr)
                table = arrow_csv.read_csv(
                    io.BytesIO(result.stdout.encode()),
                    parse_options=arrow_csv.ParseOptions(newlines_in_values=True),
                    convert_options=arrow_csv.ConvertOptions(
                        column_types=schema,
                        strings_can_be_null=True,
                        null_values=["\\N"],
                    ),
                )
                rows = list(zip(*(column.to_pylist() for column in table.columns)))
                self.assertEqual(Counter(rows), Counter(expected))
                self.assertGreater(float(result.stderr.strip()), 0)

    def test_query_hook_preserves_empty_text_null_and_quoted_csv(self):
        result = self.hook(
            "query",
            "select '' as empty_text, null::varchar as missing, 'a,\"b\nc' as quoted",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = list(csv.reader(io.StringIO(result.stdout)))
        self.assertEqual(
            rows, [["empty_text", "missing", "quoted"], ["", "\\N", 'a,"b\nc']]
        )

    def test_query_hook_accepts_sql_starting_with_comment(self):
        result = self.hook("query", "-- SQL comment\nselect 42 as answer")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["answer", "42"])

    def test_query_failure_is_nonzero_without_success_timing(self):
        result = self.hook("query", "select * from missing_clickbench_table")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing_clickbench_table", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_concurrent_clients(self):
        def run(_):
            result = self.hook("query", "select count(*) as n from hits")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["n", "2828"])

        with ThreadPoolExecutor(max_workers=10) as workers:
            list(workers.map(run, range(10)))

    def test_abrupt_http2_disconnects_preserve_native_host(self):
        server = json.loads((self.state / "server.json").read_text())
        host, port = server["address"].rsplit(":", 1)
        # The native CLI retains the default SIGPIPE disposition. A server
        # write after a peer closes must fail that connection, not kill DuckDB.
        preface = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        settings = b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
        for attempt in range(100):
            with socket.create_connection((host, int(port)), timeout=5) as peer:
                peer.sendall(preface + settings)
                if attempt % 2:
                    peer.setsockopt(
                        socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                    )
            if attempt % 10 == 0:
                harness.check(self.state)
        harness.check(self.state)
        self.assertEqual(json.loads((self.state / "server.json").read_text()), server)

    def test_restart_replaces_host_and_preserves_data(self):
        before = json.loads((self.state / "process.json").read_text())
        stopped = self.hook("stop")
        self.assertEqual(stopped.returncode, 0, stopped.stderr)
        self.assertFalse(harness.process_alive(before["pid"]))
        # A successful stop must permit immediate direct access to the same
        # database, not merely remove the Flight discovery file.
        with harness.local_database(self.state) as database:
            self.assertEqual(
                database.execute("select count(*) from hits").fetchone(), (2828,)
            )
        self.assertNotEqual(self.hook("check").returncode, 0)
        result = self.hook("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        after = json.loads((self.state / "process.json").read_text())
        self.assertNotEqual(before["nonce"], after["nonce"])
        self.assertEqual(self.hook("check").returncode, 0)
        self.assertEqual(
            self.hook("query", "select count(*) as n from hits").stdout, "n\n2828\n"
        )
        self.assertGreater(int(self.hook("data-size").stdout), 0)

    def test_load_reopens_latest_storage_and_refuses_existing_table(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            (root / "create.sql").write_text(
                "create table hits (EventDate date, EventTime timestamp, "
                "ClientEventTime timestamp, LocalEventTime timestamp)"
            )
            with harness.duckdb.connect() as database:
                database.execute(
                    "copy (select 15900 as EventDate, 42 as EventTime, "
                    "43 as ClientEventTime, 44 as LocalEventTime) to "
                    + harness.sql_string(root / "hits.parquet")
                    + " (format parquet)"
                )
            # The upstream runner starts the host before loading, so its
            # database can already exist while the hits table is still absent.
            with harness.local_database(state):
                pass
            with (
                patch.object(harness, "ROOT", root),
                patch.object(harness, "EXPECTED_ROWS", 1),
                patch.object(harness, "start"),
            ):
                harness.load(state)
                with self.assertRaises(harness.duckdb.CatalogException):
                    harness.load(state)
            with harness.local_database(state) as database:
                self.assertEqual(
                    database.execute("select epoch(EventTime) from hits").fetchall(),
                    [(42.0,)],
                )

    def test_stop_waits_for_database_lock_even_without_pid_file(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            owner = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    """import sys
import duckdb

with duckdb.connect(sys.argv[1]) as database:
    database.execute('create table probe as select 42 as answer')
    print('ready', flush=True)
    sys.stdin.readline()
""",
                    str(state / "hits.db"),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            try:
                self.assertEqual(owner.stdout.readline().strip(), "ready")
                with ThreadPoolExecutor(max_workers=1) as worker:
                    stopped = worker.submit(harness.stop, state)
                    with self.assertRaises(TimeoutError):
                        stopped.result(timeout=0.25)
                    owner.stdin.write("release\n")
                    owner.stdin.flush()
                    stopped.result(timeout=10)
                with harness.local_database(state) as database:
                    self.assertEqual(
                        database.execute("select * from probe").fetchall(), [(42,)]
                    )
            finally:
                owner.communicate(timeout=10)


class DataLakeTests(unittest.TestCase):
    def test_partitioned_listing_counts_only_matching_objects_across_pages(self):
        pages = [
            (
                b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                b"<IsTruncated>true</IsTruncated><NextContinuationToken>page2</NextContinuationToken>"
                b"<Contents><Key>data/hits_1.parquet</Key><Size>10</Size></Contents>"
                b"<Contents><Key>data/hits_1.txt</Key><Size>999</Size></Contents></ListBucketResult>"
            ),
            (
                b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
                b"<IsTruncated>false</IsTruncated>"
                b"<Contents><Key>data/hits_2.parquet</Key><Size>20</Size></Contents></ListBucketResult>"
            ),
        ]
        with (
            patch.dict(
                os.environ,
                {
                    "DUCKFLIGHT_BENCH_STORAGE": "datalake-partitioned",
                    "DUCKFLIGHT_BENCH_PARQUET_SOURCE": "s3://test/data/hits_*.parquet",
                },
            ),
            patch.object(
                harness.urllib.request,
                "urlopen",
                side_effect=[io.BytesIO(page) for page in pages],
            ) as opened,
        ):
            source = harness.lake_source()
        self.assertEqual(source["data_size"], 30)
        self.assertEqual(
            [item["key"] for item in source["objects"]],
            ["data/hits_1.parquet", "data/hits_2.parquet"],
        )
        self.assertIn("continuation-token=page2", opened.call_args_list[1].args[0])

    def test_partitioned_listing_rejects_empty_dataset(self):
        with (
            patch.dict(
                os.environ,
                {
                    "DUCKFLIGHT_BENCH_STORAGE": "datalake-partitioned",
                    "DUCKFLIGHT_BENCH_PARQUET_SOURCE": "s3://test/data/hits_*.parquet",
                },
            ),
            patch.object(
                harness.urllib.request,
                "urlopen",
                return_value=io.BytesIO(
                    b'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"/>'
                ),
            ),
            self.assertRaisesRegex(RuntimeError, "matched no objects"),
        ):
            harness.lake_source()

    def test_remote_parquet_view_through_native_flight_client(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "state"
            state.mkdir()
            for name in ["duckdb", "duckflight.duckdb_extension"]:
                shutil.copy2(ROOT / ".state" / name, state / name)
            parquet = root / "hits.parquet"
            with harness.duckdb.connect() as database:
                database.execute("install httpfs from 'https://extensions.duckdb.org'")
                database.execute(
                    "copy (select 15900 as EventDate, 42 as EventTime, 7 as UserID) to "
                    + harness.sql_string(parquet)
                    + " (format parquet)"
                )
            data = parquet.read_bytes()
            requests = []

            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def respond(self, body):
                    start, end = 0, len(data) - 1
                    requested = self.headers.get("Range")
                    requests.append(requested)
                    if requested:
                        left, right = requested.removeprefix("bytes=").split("-")
                        start = int(left) if left else max(0, len(data) - int(right))
                        end = min(int(right), end) if left and right else end
                    self.send_response(206 if requested else 200)
                    self.send_header("Content-Length", str(end - start + 1))
                    self.send_header("Accept-Ranges", "bytes")
                    if requested:
                        self.send_header(
                            "Content-Range", f"bytes {start}-{end}/{len(data)}"
                        )
                    self.end_headers()
                    if body:
                        self.wfile.write(data[start : end + 1])

                def do_HEAD(self):
                    self.respond(False)

                def do_GET(self):
                    self.respond(True)

            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with (
                    patch.dict(
                        os.environ,
                        {
                            "DUCKFLIGHT_BENCH_STORAGE": "datalake",
                            "DUCKFLIGHT_BENCH_PARQUET_SOURCE": f"http://127.0.0.1:{server.server_port}/hits.parquet",
                        },
                    ),
                    patch.object(harness, "EXPECTED_ROWS", 1),
                ):
                    try:
                        harness.load(state)
                        result = subprocess.run(
                            [str(ROOT / "query")],
                            input="select UserID, epoch(toDateTime(EventTime)) as seconds from hits",
                            text=True,
                            capture_output=True,
                            env={**os.environ, "DUCKFLIGHT_BENCH_STATE": str(state)},
                            timeout=150,
                            check=True,
                        )
                        rows = list(csv.reader(io.StringIO(result.stdout)))
                        self.assertEqual(rows[0], ["UserID", "seconds"])
                        self.assertEqual(int(rows[1][0]), 7)
                        self.assertEqual(float(rows[1][1]), 42.0)
                        self.assertGreater(float(result.stderr), 0)
                    finally:
                        harness.stop(state)
                    with harness.local_database(state) as database:
                        self.assertEqual(
                            database.execute(
                                "select table_type from information_schema.tables where table_name='hits'"
                            ).fetchone(),
                            ("VIEW",),
                        )
                    output = io.StringIO()
                    with redirect_stdout(output):
                        harness.data_size(state)
                    self.assertEqual(int(output.getvalue()), len(data))
                    self.assertTrue(any(requests))
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
