#!/usr/bin/env python3

"""Report hot-run run-to-run stability of ClickBench results.

The ranking uses the smaller of the 2nd and 3rd runtime per query (best of
the two hot runs). Both hot runs are already stored in every results file,
so the run-to-run spread — the timing noise that decides whether a small
gap between adjacent systems is real — can be measured directly from the
published data. This script does that:

  per query:   rel_spread = |run2 - run3| / min(run2, run3)
  per file:    median and p90 of rel_spread, and the share of queries whose
               hot runs differ by more than a threshold (default 10%)

Usage:

  ./hot-run-stability.py clickhouse/results/20260808/*.json
  ./hot-run-stability.py --threshold 0.2 duckdb/results/*/*.json
  ./hot-run-stability.py            # all latest active results

With no arguments, the latest results file per (system, machine) is used,
mirroring the selection in validate-results.py.
"""

import argparse
import json
import re
import statistics
import sys
from pathlib import Path

DATE_DIR_RE = re.compile(r"^\d{8}$")
SKIP_SYSTEMS = {"hardware", "versions", "gravitons"}


def find_active_result_files(root):
    latest = {}
    for path in sorted(root.glob("*/results/*/*.json")):
        relative_path = path.relative_to(root)
        if relative_path.parts[0] in SKIP_SYSTEMS:
            continue
        system, _, date_dir, filename = relative_path.parts[:4]
        if not DATE_DIR_RE.match(date_dir):
            continue
        key = (system, filename)
        if key not in latest or date_dir > latest[key].parts[2]:
            latest[key] = relative_path
    return [root / p for p in sorted(latest.values())]


def hot_run_spreads(result):
    spreads = []
    for runs in result:
        if len(runs) < 3:
            continue
        hot = [r for r in (runs[1], runs[2]) if isinstance(r, (int, float)) and r > 0]
        if len(hot) < 2:
            continue
        spreads.append(abs(hot[0] - hot[1]) / min(hot))
    return spreads


def analyze_file(path, threshold):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    spreads = hot_run_spreads(data.get("result", []))
    if not spreads:
        return None
    return {
        "path": str(path),
        "system": data.get("system", "?"),
        "machine": data.get("machine", "?"),
        "queries": len(spreads),
        "median_spread": statistics.median(spreads),
        "p90_spread": statistics.quantiles(spreads, n=10)[-1] if len(spreads) >= 2 else spreads[0],
        "share_over_threshold": sum(s > threshold for s in spreads) / len(spreads),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*", help="results JSON files (default: latest active results)")
    parser.add_argument("--threshold", type=float, default=0.1,
                        help="relative spread above which a query counts as unstable (default 0.1 = 10%%)")
    args = parser.parse_args()

    root = Path(__file__).parent
    paths = [Path(f) for f in args.files] if args.files else find_active_result_files(root)

    rows = []
    for path in paths:
        try:
            row = analyze_file(path, args.threshold)
        except (json.JSONDecodeError, OSError) as e:
            print(f"skipping {path}: {e}", file=sys.stderr)
            continue
        if row:
            rows.append(row)

    if not rows:
        print("no analyzable results", file=sys.stderr)
        return 1

    rows.sort(key=lambda r: r["median_spread"], reverse=True)
    print(f"{'system':40.40} {'machine':20.20} {'median':>8} {'p90':>8} {'>' + format(args.threshold, '.0%'):>8}")
    for r in rows:
        print(
            f"{r['system']:40.40} {r['machine']:20.20} "
            f"{r['median_spread']:8.1%} {r['p90_spread']:8.1%} {r['share_over_threshold']:8.0%}"
        )

    all_spreads = [r["median_spread"] for r in rows]
    print(
        f"\n{len(rows)} result files; median of per-file median spreads: "
        f"{statistics.median(all_spreads):.1%}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
