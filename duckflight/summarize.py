"""Convert the shared ClickBench driver's log to a submission result file."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from datetime import date
from pathlib import Path


def parse_log(text: str, throughput_status: dict | None = None) -> dict:
    results = []
    metrics = {}
    names = {
        "Load time": "load_time",
        "Data size": "data_size",
        "Concurrent QPS": "concurrent_qps",
        "Concurrent error ratio": "concurrent_error_ratio",
    }
    for line in text.splitlines():
        if re.fullmatch(r"\[[0-9.eE+, null-]+\],", line.strip()):
            values = json.loads(line.strip().removesuffix(","))
            if len(values) != 3:
                raise ValueError("expected three timings per query")
            for value in values:
                if value is not None and (not math.isfinite(value) or value < 0):
                    raise ValueError("invalid query runtime")
            results.append(values)
        for label, field in names.items():
            if line.startswith(label + ": "):
                value = json.loads(line[len(label) + 2 :])
                if value is not None and (not math.isfinite(value) or value < 0):
                    raise ValueError(f"invalid {label}")
                if field == "load_time":
                    metrics[field] = metrics.get(field, 0) + value
                else:
                    metrics[field] = value
    if len(results) != 43:
        raise ValueError(f"expected 43 queries, found {len(results)}")
    if set(metrics) != set(names.values()):
        raise ValueError("log is missing load, size or concurrency metrics")
    if not metrics["data_size"] or metrics["load_time"] is None:
        raise ValueError("log does not describe a loaded dataset")
    if (
        metrics["concurrent_qps"] is not None
        or metrics["concurrent_error_ratio"] is not None
    ) and (not throughput_status or not throughput_status.get("status")):
        raise ValueError("non-null throughput requires an explicit phase status")
    if throughput_status and throughput_status.get("status") != "complete":
        metrics["concurrent_qps"] = None
        metrics["concurrent_error_ratio"] = None
    return {**metrics, "result": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--date", required=True, type=date.fromisoformat)
    parser.add_argument("--machine", required=True)
    status = parser.add_mutually_exclusive_group()
    status.add_argument(
        "--throughput-status",
        type=Path,
        help="JSON phase status; only complete preserves QPS",
    )
    status.add_argument(
        "--throughput-unavailable", help="reason the phase was skipped or invalidated"
    )
    args = parser.parse_args()
    entry = Path(
        os.environ.get("DUCKFLIGHT_BENCH_ENTRY", Path(__file__).resolve().parent)
    )
    template = json.loads((entry / "template.json").read_text())
    throughput_status = None
    if args.throughput_status:
        throughput_status = json.loads(args.throughput_status.read_text())
        if not isinstance(throughput_status, dict) or not throughput_status.get(
            "status"
        ):
            raise ValueError("throughput status must contain a nonempty status")
    elif args.throughput_unavailable:
        throughput_status = {
            "status": "unavailable",
            "reason": args.throughput_unavailable,
        }
    result = {
        **template,
        "date": args.date.isoformat(),
        "machine": args.machine,
        "cluster_size": 1,
        **parse_log(args.log.read_text(), throughput_status),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
