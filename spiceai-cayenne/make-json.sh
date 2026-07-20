#!/bin/bash
# Converts the raw `result.csv` from `benchmark.sh` plus the `Load time:` /
# `Data size:` lines in `log` into the final json format used by the
# benchmark dashboard.
#
# usage: ./make-json.sh <machine>   # saves results/<YYYYMMDD>/<machine>.json
set -e

MACHINE=$1
[ -n "$MACHINE" ] || { echo "usage: $0 <machine>" >&2; exit 1; }

DATE=$(date -u +%Y-%m-%d)
YYYYMMDD=${DATE//-/}
mkdir -p "results/${YYYYMMDD}"

python3 - "$MACHINE" "$DATE" > "results/${YYYYMMDD}/${MACHINE}.json" <<'PY'
import csv, json, re, sys

machine, date = sys.argv[1], sys.argv[2]

runs = {}
with open("result.csv") as f:
    for query, _try, timing in csv.reader(f):
        runs.setdefault(int(query), []).append(
            None if timing == "null" else float(timing))

load_time = data_size = None
qps = err_ratio = None
with open("log") as f:
    for line in f:
        if m := re.match(r"Load time: ([\d.]+)", line):
            load_time = float(m.group(1))
        elif m := re.match(r"Data size: (\d+)", line):
            data_size = int(m.group(1))
        elif m := re.match(r"Concurrent QPS: ([\d.]+)", line):
            qps = float(m.group(1))
        elif m := re.match(r"Concurrent error ratio: ([\d.]+)", line):
            err_ratio = float(m.group(1))

template = json.load(open("template.json"))
result = {
    "system": template["system"],
    "date": date,
    "machine": machine,
    "cluster_size": 1,
    "proprietary": template["proprietary"],
    "hardware": template["hardware"],
    "tuned": template["tuned"],
    "tags": template["tags"],
    "load_time": load_time,
    "data_size": data_size,
    "concurrent_qps": qps,
    "concurrent_error_ratio": err_ratio,
    "result": [runs[q] for q in sorted(runs)],
}
print(json.dumps(result, indent=4))
PY

echo "results/${YYYYMMDD}/${MACHINE}.json"
