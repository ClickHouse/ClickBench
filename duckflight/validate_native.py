"""Validate complete Rust-client CSV against the same-file ADBC baseline.

Run baseline.py first to establish ADBC agrees with direct DuckDB. This check
then exercises the native query hook, with explicit Arrow types for large IDs.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import subprocess
from pathlib import Path

import pyarrow.csv as arrow_csv

import baseline
import harness


def compare(connection, state, sql):
    with harness.query_result(connection, sql) as expected_table:
        expected = list(zip(*(column.to_pylist() for column in expected_table.columns)))
        schema = expected_table.schema
    result = subprocess.run(
        [str(harness.ROOT / "query")],
        input=sql,
        text=True,
        capture_output=True,
        timeout=300,
        env={
            **os.environ,
            "DUCKFLIGHT_BENCH_STATE": str(state),
            "DUCKFLIGHT_BENCH_CLIENT": "rust",
        },
        check=True,
    )
    seconds = float(result.stderr.strip())
    if not math.isfinite(seconds) or seconds <= 0:
        raise RuntimeError("native hook did not emit a valid timing")
    actual_table = arrow_csv.read_csv(
        io.BytesIO(result.stdout.encode()),
        parse_options=arrow_csv.ParseOptions(newlines_in_values=True),
        convert_options=arrow_csv.ConvertOptions(
            column_types=schema,
            strings_can_be_null=True,
            null_values=["\\N"],
        ),
    )
    actual = list(zip(*(column.to_pylist() for column in actual_table.columns)))
    return expected, actual


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("DUCKFLIGHT_BENCH_STATE", harness.ROOT / ".state")),
    )
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    verified = json.loads(args.baseline.read_text())
    if len(verified["queries"]) != 43 or not all(
        row["flight_matches"] or row.get("deterministic_order_matches")
        for row in verified["queries"]
    ):
        raise RuntimeError("direct-DuckDB baseline is incomplete or failed")
    state = args.state.resolve()
    report = {"client": "Apache Arrow Rust 60.0.0", "queries": []}
    harness.start(state)
    try:
        with harness.connect(state) as connection:
            with harness.query_result(connection, "select count(*) from hits") as table:
                if table.column(0)[0].as_py() != harness.EXPECTED_ROWS:
                    raise RuntimeError("native validation requires the full dataset")
            for number, sql in enumerate(
                harness.query_file().read_text().splitlines(), 1
            ):
                expected, actual = compare(connection, state, sql)
                matched = baseline.same_rows(expected, actual)
                entry = {
                    "query": number,
                    "row_count": len(actual),
                    "native_matches": matched,
                }
                if not matched:
                    if not expected:
                        raise RuntimeError(
                            f"native returned unexpected rows in query {number}"
                        )
                    ordered = baseline.ordered_validation_sql(sql, len(expected[0]))
                    expected, actual = compare(connection, state, ordered)
                    matched = baseline.same_rows(expected, actual)
                    entry["validation_query"] = ordered
                    entry["deterministic_order_matches"] = matched
                report["queries"].append(entry)
                args.output.write_text(json.dumps(report, indent=2))
                print(f"Native validation query {number}: {matched}", flush=True)
                if not matched:
                    raise RuntimeError(f"native result mismatch in query {number}")
    finally:
        harness.stop(state)
    report["validation"] = (
        "All 43 native query results agree with the validated same-file baseline."
    )
    args.output.write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
