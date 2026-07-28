#!/usr/bin/env python3
"""Assemble a ClickBench results/<YYYYMMDD>/<machine>.json from a benchmark log.

This is a HELPER, not a ClickBench hook — run it after `./benchmark.sh | tee LOG`
to turn the raw run output into the JSON that gets committed in the PR.

It reads the standard ClickBench log format emitted by ./benchmark.sh:
  - one or more `Load time: <sec>` lines   (summed, then rounded to an int like
    every peer result file)
  - a `Data size: <bytes>` line            (falls back to the parquet-single
    constant if absent)
  - 43 lines of `[cold, hot1, hot2],`      (the per-query runtimes)
plus template.json (system / proprietary / hardware / tuned / tags), and writes a
VALID results JSON to results/<YYYYMMDD>/<machine>.json with the same field order
and shape as the other systems' files.

Usage:
  ./make-result.py LOG
  ./make-result.py LOG --machine c6a.4xlarge --date 2026-07-23
  ./make-result.py LOG --template template.json --outdir results

Exits non-zero (with a clear message) if the log is malformed, so a bad file is
never written into results/.
"""
import argparse
import datetime
import json
import os
import re
import sys

# hits.parquet (single) is a fixed-size file; every peer reports this exact size.
DEFAULT_DATA_SIZE = 14779976446


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", help="benchmark output captured via `| tee LOG`")
    ap.add_argument("--machine", default="c6a.4xlarge",
                    help="hardware label + result filename (default: c6a.4xlarge)")
    ap.add_argument("--date", default=None,
                    help="run date YYYY-MM-DD (default: today in UTC)")
    ap.add_argument("--template", default=None,
                    help="path to template.json (default: alongside this script)")
    ap.add_argument("--outdir", default=None,
                    help="results directory (default: <script dir>/results)")
    ap.add_argument("--data-size", type=int, default=None,
                    help="override data_size in bytes (default: read from log, "
                         "else %d)" % DEFAULT_DATA_SIZE)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    template_path = args.template or os.path.join(here, "template.json")
    outdir = args.outdir or os.path.join(here, "results")

    try:
        text = open(args.log, encoding="utf-8", errors="replace").read()
    except OSError as e:
        sys.exit("cannot read log %s: %s" % (args.log, e))

    # Load time: sum every "Load time:" line (ClickBench allows one or more),
    # then round to an integer to match every committed peer result.
    loads = re.findall(r'(?mi)^\s*Load\s*time:\s*([0-9]+(?:\.[0-9]+)?)', text)
    if not loads:
        sys.exit("no 'Load time:' line found in %s" % args.log)
    load_time = round(sum(float(x) for x in loads))

    # Data size: prefer the log, then --data-size, then the known constant.
    m = re.search(r'(?mi)^\s*Data\s*size:\s*([0-9]+)', text)
    if m:
        data_size = int(m.group(1))
    elif args.data_size is not None:
        data_size = args.data_size
    else:
        data_size = DEFAULT_DATA_SIZE

    # 43 result triples: "[c, h1, h2]" (trailing comma optional). The three-float
    # bracket shape is specific enough that log noise won't match; we still assert
    # the count so a short/long capture is rejected rather than silently written.
    triples = [
        [float(a), float(b), float(c)]
        for a, b, c in re.findall(
            r'\[\s*([0-9.eE+-]+)\s*,\s*([0-9.eE+-]+)\s*,\s*([0-9.eE+-]+)\s*\]', text)
    ]
    if len(triples) != 43:
        sys.exit("expected 43 result rows, found %d in %s" % (len(triples), args.log))

    try:
        tpl = json.load(open(template_path))
    except (OSError, ValueError) as e:
        sys.exit("cannot read template %s: %s" % (template_path, e))
    for key in ("system", "proprietary", "hardware", "tuned", "tags"):
        if key not in tpl:
            sys.exit("template %s is missing required key '%s'" % (template_path, key))

    date = args.date or datetime.datetime.utcnow().strftime("%Y-%m-%d")
    folder = date.replace("-", "")

    # Same field order as the other systems' result files.
    result = {
        "system": tpl["system"],
        "date": date,
        "machine": args.machine,
        "cluster_size": tpl.get("cluster_size", 1),
        "proprietary": tpl["proprietary"],
        "hardware": tpl["hardware"],
        "tuned": tpl["tuned"],
        "tags": tpl["tags"],
        "load_time": load_time,
        "data_size": data_size,
        "concurrent_qps": None,
        "concurrent_error_ratio": None,
        "result": triples,
    }

    dest_dir = os.path.join(outdir, folder)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, "%s.json" % args.machine)
    with open(dest, "w") as f:
        f.write(format_result_json(result))

    # Re-parse what we just wrote to guarantee valid JSON before we report success.
    json.load(open(dest))
    print("wrote %s" % dest)
    print("  load_time = %d s   data_size = %d   queries = %d"
          % (load_time, data_size, len(triples)))


def format_result_json(result):
    """Serialize like the other ClickBench result files: the object is
    pretty-printed at 4 spaces, `tags` stays on one line, and each `result`
    triple sits on its own single line (`[cold, hot1, hot2],`) instead of being
    split one-number-per-line the way json.dump(indent=4) would."""
    order = ["system", "date", "machine", "cluster_size", "proprietary",
             "hardware", "tuned", "tags", "load_time", "data_size",
             "concurrent_qps", "concurrent_error_ratio", "result"]
    keys = order + [k for k in result if k not in order]
    parts = []
    for key in keys:
        if key not in result:
            continue
        if key == "result":
            rows = ",\n".join(
                "        [%s]" % ", ".join(json.dumps(v) for v in row)
                for row in result["result"]
            )
            parts.append('    "result": [\n%s\n    ]' % rows)
        else:
            parts.append("    %s: %s" % (json.dumps(key), json.dumps(result[key])))
    return "{\n" + ",\n".join(parts) + "\n}\n"


if __name__ == "__main__":
    main()
