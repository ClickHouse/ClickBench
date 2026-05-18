#!/usr/bin/env python3
"""
Parse the benchmark.sh log into the standard ClickBench result JSON.

We do two extra steps that the default `[t1,t2,t3]` line parsing in
benchmark-common.sh wouldn't do on its own:

1. Q29 timing — the first benchmark run captured `[null,null,null]` for
   Q29 because the original `./query` script's awk-based matcher choked
   on the regex backslashes in Q29's SQL. The matcher was fixed and Q29
   was re-run; we splice the corrected `[cold, warm, warm]` triple into
   the result list here so we don't have to redo the entire ~60-min run.

2. Cold + generation-time policy — GenDB's per-query .cpp files were
   synthesized once, offline, by an LLM. ClickBench measures the
   end-to-end engine path, and "compile this query" is part of GenDB's
   query path the same way "JIT this plan" is part of HyPer's or
   "translate this expression" is part of any code-generating engine.
   Following the project policy in generation_times.json we add each
   query's generation time to ITS cold (first-try) timing only; warm
   tries are unchanged because they reuse the compiled binary on disk
   that the cold try already paid for.
"""
import json
import re
import sys
from pathlib import Path

GENDB_DIR = Path(__file__).resolve().parent
LOG = Path("/tmp/bench.log")

# 1. Pull [t1,t2,t3] lines in order from the log.
triples_re = re.compile(r"^\[([^\]]+)\],\s*$")
triples = []
for ln in LOG.read_text().splitlines():
    m = triples_re.match(ln)
    if not m:
        continue
    parts = m.group(1).split(",")
    row = [None if p.strip() == "null" else float(p) for p in parts]
    triples.append(row)

if len(triples) != 43:
    print(f"warn: expected 43 triples, got {len(triples)}", file=sys.stderr)

# 2. Splice Q29 with the post-fix re-run numbers captured below.
#    Cold from the post-fix `drop_caches && ./query` cycle, then two
#    consecutive runs on warm pagecache.
triples[28] = [86.370970, 0.597417, 0.609257]

# 3. Add generation time to each cold try.
gentimes = json.loads((GENDB_DIR / "generation_times.json").read_text())["seconds"]
for i, row in enumerate(triples):
    q = f"q{i + 1}"
    gen = gentimes[q]
    if row[0] is not None:
        row[0] = round(row[0] + gen, 3)
    # round the warms too — matches existing ClickBench result precision
    for j in (1, 2):
        if row[j] is not None:
            row[j] = round(row[j], 3)

# 4. Pull the other measurements from the log.
def grab(prefix):
    for ln in LOG.read_text().splitlines():
        if ln.startswith(prefix):
            return ln[len(prefix):].strip()
    return None

load_time = float(grab("Load time: "))
data_size = int(grab("Data size: "))
qps = float(grab("Concurrent QPS: "))
err_ratio = float(grab("Concurrent error ratio: "))

template = json.loads((GENDB_DIR / "template.json").read_text())

# 5. Assemble the result JSON, in the same shape ClickBench expects.
out = {
    "system": template["system"],
    "date": "2026-05-18",
    "machine": "c8g.24xlarge",  # adjust per environment if rerunning
    "cluster_size": 1,
    "proprietary": template["proprietary"],
    "hardware": template["hardware"],
    "tuned": template["tuned"],
    "tags": template["tags"],
    "load_time": round(load_time, 3),
    "data_size": data_size,
    "concurrent_qps": qps,
    "concurrent_error_ratio": err_ratio,
    "result": triples,
}

print(json.dumps(out, indent=4))
