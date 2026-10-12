"""Run a direct-DuckDB baseline and compare full-dataset Flight SQL results.

Run on the dedicated Linux benchmark host after benchmark.sh. This is a
same-file comparison, not a second standalone ClickBench submission.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import subprocess
import time
from pathlib import Path

import harness


def same_rows(expected, actual):
    """Match row multisets, allowing floating aggregate rounding differences."""
    if len(expected) != len(actual):
        return False
    remaining = list(actual)
    for row in expected:
        for index, candidate in enumerate(remaining):
            if len(row) != len(candidate):
                continue
            equal = True
            for left, right in zip(row, candidate):
                if isinstance(left, float) and isinstance(right, float):
                    equal = math.isclose(left, right, rel_tol=1e-10, abs_tol=1e-9)
                else:
                    equal = left == right
                if not equal:
                    break
            if equal:
                remaining.pop(index)
                break
        else:
            return False
    return True


def ordered_validation_sql(sql, column_count):
    limit = re.search(r"\bLIMIT \d+(?: OFFSET \d+)?;\s*$", sql, re.IGNORECASE)
    if limit is None:
        raise ValueError("cannot resolve a difference without a final LIMIT")
    prefix = sql[: limit.start()].rstrip()
    separator = (
        ", " if re.search(r"\bORDER BY\b", prefix, re.IGNORECASE) else " ORDER BY "
    )
    return (
        prefix
        + separator
        + ", ".join(str(i) for i in range(1, column_count + 1))
        + " "
        + sql[limit.start() :]
    )


def resolve_ties(state, output, report, queries):
    pending = [entry for entry in report["queries"] if not entry["flight_matches"]]
    harness.stop(state)
    expected = {}
    with harness.local_database(state) as database:
        for entry in pending:
            number = entry["query"]
            sql = ordered_validation_sql(
                queries[number - 1], len(entry["direct_rows"][0])
            )
            entry["validation_query"] = sql
            expected[number] = database.execute(sql).fetchall()
    harness.start(state)
    try:
        with harness.connect(state) as connection:
            for entry in pending:
                number = entry["query"]
                with harness.query_result(
                    connection, entry["validation_query"]
                ) as table:
                    actual = list(
                        zip(*(column.to_pylist() for column in table.columns))
                    )
                entry["deterministic_order_matches"] = same_rows(
                    expected[number], actual
                )
                if not entry["deterministic_order_matches"]:
                    entry["validation_direct_rows"] = expected[number]
                    entry["validation_flight_rows"] = actual
                output.write_text(json.dumps(report, indent=2, default=str))
                print(
                    f"Deterministic validation query {number}: {entry['deterministic_order_matches']}",
                    flush=True,
                )
    finally:
        harness.stop(state)
    failures = [
        entry["query"] for entry in pending if not entry["deterministic_order_matches"]
    ]
    if failures:
        raise RuntimeError(f"substantive result differences: {failures}")
    report["validation"] = (
        "All 43 queries agree; nonunique LIMIT ordering resolved with validation-only tie breakers. Timed SQL unchanged."
    )
    output.write_text(json.dumps(report, indent=2, default=str))


def main():
    queries = (harness.ROOT / "queries.sql").read_text().splitlines()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("DUCKFLIGHT_BENCH_STATE", harness.ROOT / ".state")),
    )
    parser.add_argument("--output", type=Path, default=harness.ROOT / "baseline.json")
    parser.add_argument("--resolve-ties", action="store_true")
    args = parser.parse_args()
    state = args.state.resolve()
    output = args.output.resolve()
    if args.resolve_ties:
        resolve_ties(state, output, json.loads(output.read_text()), queries)
        return
    report = {"duckdb_version": harness.DUCKDB_VERSION, "queries": []}
    expected = []
    harness.stop(state)
    with harness.local_database(state) as database:
        count = database.execute("select count(*) from hits").fetchone()[0]
        if count != harness.EXPECTED_ROWS:
            raise RuntimeError(f"expected full dataset, found {count} rows")
    for number, sql in enumerate(queries, 1):
        subprocess.run(
            ["sudo", "sh", "-c", "sync; echo 3 > /proc/sys/vm/drop_caches"],
            check=True,
        )
        times = []
        for _ in range(3):
            # Match the native DuckDB entry: a fresh host connection per try.
            with harness.local_database(state) as database:
                began = time.perf_counter()
                rows = database.execute(sql).fetchall()
                times.append(time.perf_counter() - began)
        expected.append(rows)
        report["queries"].append({"query": number, "direct_seconds": times})
        output.write_text(json.dumps(report, indent=2))
        print(f"Direct query {number}: {times}", flush=True)
    harness.start(state)
    mismatches = []
    try:
        with harness.connect(state) as connection:
            for number, (sql, rows) in enumerate(zip(queries, expected), 1):
                with harness.query_result(connection, sql) as table:
                    actual = list(
                        zip(*(column.to_pylist() for column in table.columns))
                    )
                matches = same_rows(rows, actual)
                entry = report["queries"][number - 1]
                entry["flight_matches"] = matches
                entry["row_count"] = len(actual)
                if not matches:
                    mismatches.append(number)
                    entry["direct_rows"] = rows
                    entry["flight_rows"] = actual
                output.write_text(json.dumps(report, indent=2, default=str))
                print(
                    f"Flight query {number}: {'matches' if matches else 'REVIEW REQUIRED'}",
                    flush=True,
                )
    finally:
        harness.stop(state)
    if mismatches:
        resolve_ties(state, output, report, queries)
    else:
        report["validation"] = "All 43 query result multisets agree."
        output.write_text(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
