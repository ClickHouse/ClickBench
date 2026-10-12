"""Convert the shared ClickBench driver's log to a submission result file."""

from __future__ import annotations

import argparse
import json
import math
import re
from datetime import date
from pathlib import Path


def parse_log(text: str) -> dict:
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
    return {**metrics, "result": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--date", required=True, type=date.fromisoformat)
    parser.add_argument("--machine", required=True)
    args = parser.parse_args()
    template = json.loads(Path(__file__).with_name("template.json").read_text())
    result = {
        **template,
        "date": args.date.isoformat(),
        "machine": args.machine,
        "cluster_size": 1,
        **parse_log(args.log.read_text()),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")


if __name__ == "__main__":
    main()
