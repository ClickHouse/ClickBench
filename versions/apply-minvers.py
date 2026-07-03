#!/usr/bin/env python3
# Normalise the committed result files to the current per-query minimum versions
# (queries/<ds>.minver). fetch-results.sh pulls RAW data from the sink, which reflects the
# minvers that were in effect WHEN each version ran -- not the current ones -- so this makes
# every result consistent with the current minvers regardless of when it was benchmarked:
#
#   * a query below its minimum version is nulled (its whole per-query timing array), and
#   * a dataset every query of which is above the version (i.e. the version is below the
#     dataset's lowest minimum) has its load_time / data_size dropped too -- such a version
#     never loads that dataset, so it must not report a size or load time for it.
#
# Idempotent: re-running on already-normalised files changes nothing. Edits go through jq so
# untouched number literals keep their exact formatting (matching fetch-results.sh's jq -cS).

import glob, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)

# Same fixed order the runner concatenates per-dataset results in (see run-version.sh).
QUERY_ORDER = ["mgbench", "ssb", "hits", "uk", "ontime", "taxi", "coffeeshop", "tpch", "tpcds", "job"]

def sql_count(ds):
    with open(f"queries/{ds}.sql") as f:
        return sum(1 for line in f if line.strip())

def minver_lines(ds):
    with open(f"queries/{ds}.minver") as f:
        return [line.strip() for line in f if line.strip() != ""]

# Version key mirroring run-version.sh's version_key: a bare build number is a 1.1.<n>
# snapshot; dotted versions use their components (missing -> 0).
def vkey(v):
    if v == "master":            # the dev build is the newest
        return (999999, 0, 0, 0)
    if re.fullmatch(r"\d+", v):
        return (1, 1, int(v), 0)
    parts = v.split(".")
    return tuple(int(parts[i]) if i < len(parts) and parts[i].isdigit() else 0 for i in range(4))

def below(v, m):            # "0" == no minimum
    return m != "0" and vkey(v) < vkey(m)

# Build the global (concatenated) minver list and each dataset's [start,end) span + minimum.
global_minver = []
spans = {}          # ds -> (start, end)
dmin = {}           # ds -> lowest minimum ("0" if any query runs everywhere)
for ds in QUERY_ORDER:
    n = sql_count(ds)
    mvs = minver_lines(ds)
    if len(mvs) != n:
        sys.exit(f"{ds}: {len(mvs)} minver lines != {n} queries")
    start = len(global_minver)
    global_minver.extend(mvs)
    spans[ds] = (start, start + n)
    dmin[ds] = "0" if any(m == "0" for m in mvs) else min(mvs, key=vkey)

edited = 0
for f in sorted(glob.glob("results/*.json")):
    v = subprocess.check_output(["jq", "-r", ".version", f], text=True).strip()
    idx = [i for i, m in enumerate(global_minver) if below(v, m)]
    drop = [ds for ds in QUERY_ORDER if below(v, dmin[ds])]
    if not idx and not drop:
        continue
    prog = ("reduce $idx[] as $i (.; .result[$i] |= map(null)) "
            "| reduce $drop[] as $d (.; del(.load_time[$d], .data_size[$d]))")
    out = subprocess.check_output(
        ["jq", "-cS", "--argjson", "idx", str(idx), "--argjson", "drop",
         "[" + ",".join(f'"{d}"' for d in drop) + "]", prog, f])
    with open(f, "wb") as fh:
        fh.write(out)
    edited += 1

print(f"apply-minvers: normalised {edited} result file(s) to current minvers", file=sys.stderr)
