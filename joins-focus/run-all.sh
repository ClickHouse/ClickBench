#!/usr/bin/env bash
# Run every system, one at a time, then regenerate the page.
#
#   ./run-all.sh                          # all 7 systems, all 3 benchmarks
#   ./run-all.sh --benchmarks tpch        # all 7 systems, TPC-H only
#   ./run-all.sh --systems "clickhouse duckdb"
#   STATISTICS=1 ./run-all.sh             # every system collects statistics after loading
#
# A system that fails does not stop the run -- its results file simply reports null for the
# queries it could not time, and the others still complete. The exit status is 0 unless every
# system failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ALL_SYSTEMS="clickhouse duckdb starrocks cedardb doris umbra firebolt"
SYSTEMS="${SYSTEMS:-${ALL_SYSTEMS}}"
BENCHMARKS="${BENCHMARKS:-tpch tpcds job}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --systems)    SYSTEMS="$2"; shift 2 ;;
        --benchmarks) BENCHMARKS="$2"; shift 2 ;;
        -h|--help)    sed -n '2,16p' "$0" | sed 's/^#\( \|$\)//'; exit 0 ;;
        *) echo "unknown option: $1 (want --systems / --benchmarks)" >&2; exit 1 ;;
    esac
done

# Every system lives in its own directory with its own run.sh.
runner_of() { printf '%s/%s/run.sh' "${HERE}" "$1"; }

mkdir -p "${HERE}/logs"
ok=0 failed=""
for s in ${SYSTEMS}; do
    r="$(runner_of "${s}")"
    [ -x "${r}" ] || { echo "no runner for ${s} (${r})" >&2; failed+=" ${s}"; continue; }
    echo "=== ${s}: ${BENCHMARKS} (log: logs/${s}/<run>.log) ===" >&2
    if "${r}" ${BENCHMARKS}; then
        ok=$((ok + 1))
        log="$(ls -t "${HERE}/logs/${s}"/*.log 2>/dev/null | head -1)"
        # grep -c PRINTS 0 and EXITS 1 when nothing matches, so `|| echo 0` fired as well and
        # the count came out as two lines ("0\n0"). Capture it, then default an empty capture.
        n=$(grep -c '^q[0-9]* .*\[' "${log:-/dev/null}" 2>/dev/null); n=${n:-0}
        echo "--- ${s}: ${n} queries logged (${log:-no log written})" >&2
    else
        echo "--- ${s}: FAILED (see logs/${s}/)" >&2
        failed+=" ${s}"
    fi
done

echo >&2
echo "=== summary ===" >&2
python3 - "${HERE}" <<'PY' >&2
import json, glob, os, sys
root = sys.argv[1]
def ran(row): return isinstance(row, list) and any(v is not None for v in row)
spans = (("tpch", 0, 22), ("tpcds", 22, 125), ("job", 125, 238))
print(f'{"system":12} {"version":12} {"tpch":>8} {"tpcds":>8} {"job":>8}')
# results/<system>/<timestamp>.json, plus the older flat form. Show the NEWEST file per system,
# which is the run that just finished.
files = (glob.glob(os.path.join(root, "results", "*", "*.json")) +
         glob.glob(os.path.join(root, "results", "*.json")))
newest = {}
for f in sorted(files, key=os.path.getmtime):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get("system"):
        newest[d["system"]] = (f, d)
for system in sorted(newest):
    f, d = newest[system]
    r = d.get("result") or []
    cells = [f'{sum(1 for x in r[a:b] if ran(x))}/{b-a}' for _, a, b in spans]
    print(f'{system:12} {d.get("version",""):12} ' + " ".join(f"{c:>8}" for c in cells))
PY

"${HERE}/generate-results.sh" --passed >&2 || true
[ "${ok}" -gt 0 ] || { echo "every system failed:${failed}" >&2; exit 1; }
[ -n "${failed}" ] && echo "failed:${failed}" >&2
exit 0
