#!/usr/bin/env python3

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path


EXPECTED_QUERIES = 43
EXPECTED_RUNS = 3
OUTLIER_SECONDS = 24 * 60 * 60
DATE_DIR_RE = re.compile(r"^\d{8}$")
ISO_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SKIP_SYSTEMS = {"hardware", "versions", "gravitons"}


def find_result_files(root):
    files = []
    for path in root.glob("*/results/*/*.json"):
        relative_path = path.relative_to(root)
        if relative_path.parts[0] in SKIP_SYSTEMS:
            continue
        files.append(relative_path)
    return sorted(files)


def active_result_files(files):
    latest = {}
    for path in files:
        system, _, date_dir, filename = path.parts[:4]
        if not DATE_DIR_RE.match(date_dir):
            continue
        key = (system, filename)
        if key not in latest or date_dir > latest[key].parts[2]:
            latest[key] = path
    return set(latest.values())


def is_iso_date(value):
    if not isinstance(value, str) or not ISO_DATE_RE.match(value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return False
    return True


def add(problems, severity, path, message):
    problems.append((severity, str(path), message))


def validate_metadata(path, data, problems):
    _, _, date_dir, _ = path.parts[:4]

    if not DATE_DIR_RE.match(date_dir):
        add(problems, "error", path, f"result directory date must be YYYYMMDD, got {date_dir!r}")

    if not isinstance(data.get("system"), str) or not data["system"].strip():
        add(problems, "error", path, "system must be a non-empty string")

    if not isinstance(data.get("machine"), str) or not data["machine"].strip():
        add(problems, "error", path, "machine must be a non-empty string")

    if not is_iso_date(data.get("date")):
        add(problems, "error", path, "date must be a valid YYYY-MM-DD string")
    else:
        expected = f"{date_dir[:4]}-{date_dir[4:6]}-{date_dir[6:8]}"
        if data["date"] != expected:
            add(problems, "warning", path, f"date {data['date']!r} differs from directory date {expected!r}")

    tags = data.get("tags")
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        add(problems, "error", path, "tags must be an array of strings")


def validate_result_matrix(path, data, active, problems):
    result = data.get("result")
    tags = data.get("tags") if isinstance(data.get("tags"), list) else []
    is_historical = "historical" in tags
    severity = "error" if active and not is_historical else "warning"

    if not isinstance(result, list):
        add(problems, severity, path, "result must be an array")
        return

    if len(result) != EXPECTED_QUERIES:
        add(problems, severity, path, f"result must contain {EXPECTED_QUERIES} query rows, got {len(result)}")

    for query_index, row in enumerate(result, 1):
        if not isinstance(row, list):
            add(problems, severity, path, f"result row {query_index} must be an array")
            continue

        if len(row) != EXPECTED_RUNS:
            add(problems, severity, path, f"result row {query_index} must contain {EXPECTED_RUNS} timings, got {len(row)}")

        for run_index, value in enumerate(row, 1):
            if value is None:
                continue
            if not isinstance(value, (int, float)):
                add(problems, severity, path, f"result row {query_index}, run {run_index} must be a number or null")
                continue
            if value < 0:
                add(problems, severity, path, f"result row {query_index}, run {run_index} must not be negative")
            if value > OUTLIER_SECONDS:
                add(
                    problems,
                    "warning",
                    path,
                    f"result row {query_index}, run {run_index} is unusually high: {value} seconds",
                )


def validate_file(root, path, active, problems):
    try:
        with (root / path).open(encoding="utf-8") as handle:
            data = json.load(handle)
    except json.JSONDecodeError as exc:
        add(problems, "error", path, f"invalid JSON: {exc}")
        return

    if not isinstance(data, dict):
        add(problems, "error", path, "top-level JSON value must be an object")
        return

    if "error" in data:
        if not isinstance(data["error"], str) or not data["error"].strip():
            add(problems, "error", path, "error entries must contain a non-empty error string")
        return

    validate_metadata(path, data, problems)
    validate_result_matrix(path, data, active, problems)


def main():
    parser = argparse.ArgumentParser(description="Validate main ClickBench result JSON files.")
    parser.add_argument("root", nargs="?", default=".", help="repository root")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    files = find_result_files(root)
    active_files = active_result_files(files)
    problems = []

    for path in files:
        validate_file(root, path, path in active_files, problems)

    warnings = [problem for problem in problems if problem[0] == "warning"]
    errors = [problem for problem in problems if problem[0] == "error"]

    for severity, path, message in problems:
        print(f"{severity}: {path}: {message}", file=sys.stderr)

    print(f"Validated {len(files)} result files ({len(active_files)} active).", file=sys.stderr)
    if warnings:
        print(f"Warnings: {len(warnings)}", file=sys.stderr)
    if errors:
        print(f"Errors: {len(errors)}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
