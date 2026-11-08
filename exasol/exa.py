#!/usr/bin/env python3
# Small pyexasol wrapper used by ./check, ./load, ./query and ./data-size.
#
#   exa.py check             connect and run SELECT 1
#   exa.py query             run the query from stdin; print the result to
#                            stdout and the runtime in seconds to stderr
#   exa.py sql               run the statements from stdin, separated by ';'
#   exa.py import <file>     import a TSV file into HITS
#   exa.py scalar <query>    print the single value returned by the query

import json
import os
import ssl
import sys
import timeit

import pyexasol

DIR = os.path.dirname(os.path.abspath(__file__))
DEPLOYMENT_DIR = os.path.join(DIR, "deploy")


def connect(schema="CLICKBENCH"):
    with open(os.path.join(DEPLOYMENT_DIR, "secrets.json")) as f:
        password = json.load(f)["dbPassword"]
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"127.0.0.1:{port}",
        user="sys",
        password=password,
        schema=schema,
        compression=False,
        encryption=True,
        # The local deployment uses a self-signed certificate.
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
        fetch_dict=False,
        socket_timeout=86400,
        query_timeout=0,
    )


def main():
    command = sys.argv[1]

    if command == "check":
        connection = connect(schema="")
        connection.execute("SELECT 1").fetchall()
        return

    if command == "sql":
        connection = connect(schema="")
        for statement in sys.stdin.read().split(";"):
            if statement.strip():
                connection.execute(statement)
        return

    if command == "scalar":
        connection = connect()
        print(connection.execute(sys.argv[2]).fetchval())
        return

    if command == "import":
        connection = connect()
        # The TSV has timestamps without fractional seconds.
        connection.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS'")
        connection.import_from_file(
            sys.argv[2],
            "HITS",
            import_params={
                "column_separator": "\t",
                "row_separator": "LF",
                "encoding": "UTF8",
                # ClickHouse writes TSV without quoting; use a character that
                # never occurs in the data so that '"' is taken literally.
                "column_delimiter": "\x01",
            },
        )
        return

    if command == "query":
        query = sys.stdin.read().strip().rstrip(";")
        connection = connect()
        # The query result cache would answer the 2nd and 3rd runs from memory.
        connection.execute("ALTER SESSION SET QUERY_CACHE = 'OFF'")
        connection.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS'")
        start = timeit.default_timer()
        rows = connection.execute(query).fetchall()
        end = timeit.default_timer()
        for row in rows:
            print("\t".join("NULL" if v is None else str(v) for v in row))
        print(f"{end - start:.3f}", file=sys.stderr)
        return

    raise SystemExit(f"unknown command {command}")


if __name__ == "__main__":
    main()
