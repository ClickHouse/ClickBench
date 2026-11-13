#!/bin/bash
# Runs the randomized benchmark for one system on this machine.
#
# Usage: run-system.sh <system> <payload dir> <work dir>
#
# <payload dir> has queries.json (the generated queries) and translated.json
# (the queries for this system). Environment:
#   RANDOM_SEED, RANDOM_ROWS, ...   the dataset, see generate-data.sh
#   RANDOM_CLICKHOUSE_VERSION       the pinned ClickHouse release
#   RANDOM_PARALLEL_QUERIES         concurrent workers, default 4
#   RANDOM_REPEATS                  how many times every query runs, default 3
#   RANDOM_QUERY_TIMEOUT            seconds per query, default 600
#   RANDOM_REFERENCE_TIMEOUT        seconds per reference query, default 1800
#
# The system's own scripts from the main benchmark are used as they are
# (install, start, check, load, query, data-size, stop), with the files of
# random/systems/<system>/ copied over them when there are any (e.g. a ./query
# that prints the whole result). The system loads the generated data in the
# format of its BENCH_DOWNLOAD_SCRIPT.
#
# Writes <work dir>/result.json.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SYSTEM="${1:?usage: run-system.sh <system> <payload dir> <work dir>}"
PAYLOAD="$(cd "${2:?}" && pwd)"
WORK="${3:?}"
mkdir -p "${WORK}"
WORK="$(cd "${WORK}" && pwd)"
: "${RANDOM_PARALLEL_QUERIES:=4}"
: "${RANDOM_REPEATS:=3}"
: "${RANDOM_QUERY_TIMEOUT:=600}"
: "${RANDOM_REFERENCE_TIMEOUT:=1800}"
: "${RANDOM_ROWS:=1000000000}"
export RANDOM_ROWS

log() { echo "random: $*"; }
# Flushes the writeback outside of the measured windows, and inside the load
# (as the main benchmark does). RANDOM_SKIP_SYNC=1 is for testing on a shared
# host, where sync waits for everyone's writes.
flush() { [ -n "${RANDOM_SKIP_SYNC:-}" ] || sync; }

install_random_clickhouse "${RANDOM_CLICKHOUSE_VERSION:?}"

# RANDOM_SYSTEMS_DIR: where the system directories are, for testing (default: ClickBench).
SYSTEM_DIR="${RANDOM_SYSTEMS_DIR:-${CLICKBENCH_DIR}}/${SYSTEM}"
cd "${SYSTEM_DIR}"
if [ -d "${RANDOM_DIR}/systems/${SYSTEM}" ]; then
    for f in "${RANDOM_DIR}/systems/${SYSTEM}"/*; do
        case "$(basename "$f")" in config|notes.md|docs) ;; *) cp -a "$f" . ;; esac
    done
fi

# The settings of the system from its benchmark.sh (BENCH_DOWNLOAD_SCRIPT, ...).
eval "$(grep -E '^\s*export BENCH_[A-Z_]+=' benchmark.sh)"
: "${BENCH_DOWNLOAD_SCRIPT:=}"
: "${BENCH_DURABLE:=yes}"
: "${BENCH_RESTARTABLE:=yes}"
: "${BENCH_CHECK_TIMEOUT:=300}"
export BENCH_DURABLE
# random/systems/<system>/config may override these (for a system that sets
# them elsewhere than in benchmark.sh) and set RANDOM_DATA_DIR: where the
# system expects its files, if not in its directory.
[ -f "${RANDOM_DIR}/systems/${SYSTEM}/config" ] && source "${RANDOM_DIR}/systems/${SYSTEM}/config"
: "${RANDOM_DATA_DIR:=.}"

# Some load scripts check for the exact number of rows of the original
# dataset (99997497) to catch partial loads: check for the generated number.
if [ -f load ] && grep -q '99997497' load; then
    sed -i "s/99997497/${RANDOM_ROWS}/g" load
    log "./load checks the row count; it expects ${RANDOM_ROWS} rows now"
fi

check_loop() {
    local i
    for i in $(seq 1 "${BENCH_CHECK_TIMEOUT}"); do
        ./check >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "random: ./check did not succeed within ${BENCH_CHECK_TIMEOUT} s" >&2
    return 1
}

# The system first, the data then: a broken install fails in minutes, not
# after the generation of the data.
log "installing"
./install
flush
./start >/dev/null 2>&1 || true
check_loop

log "generating the data"
"${RANDOM_DIR}/lib/generate-data.sh" "${WORK}/data"

log "making the files for ${BENCH_DOWNLOAD_SCRIPT}"
"${RANDOM_DIR}/lib/make-format.sh" "${WORK}/data" "${BENCH_DOWNLOAD_SCRIPT}" "${RANDOM_DATA_DIR}"
flush

log "loading"
start=$(date +%s.%N)
./load
flush
load_time=$(awk -v s="${start}" -v e="$(date +%s.%N)" 'BEGIN { printf "%.3f", e - s }')
echo "Load time: ${load_time}"
# A restart after the load, as the main benchmark does before every cold
# run: some systems load in a separate process and see the data only after a
# restart (Rayforce opens its table at start). The queries then run from a
# freshly started system. An in-memory system (BENCH_DURABLE=no) keeps
# running: a restart would lose its data.
if [ "${BENCH_RESTARTABLE}" = "yes" ] && [ "${BENCH_DURABLE}" = "yes" ]; then
    ./stop >/dev/null 2>&1 || true
    for i in $(seq 1 60); do ./check >/dev/null 2>&1 || break; sleep 1; done
    ./start >/dev/null 2>&1 || true
fi
check_loop
data_size=$(./data-size || echo null)
echo "Data size: ${data_size}"

log "running the queries"
python3 "${RANDOM_DIR}/lib/driver.py" --queries "${PAYLOAD}/translated.json" --output "${WORK}/run" \
    --parallel "${RANDOM_PARALLEL_QUERIES}" --repeats "${RANDOM_REPEATS}" \
    --timeout "${RANDOM_QUERY_TIMEOUT}" --seed "${RANDOM_SEED}"
data_size_after=$(./data-size || echo null)
./stop >/dev/null 2>&1 || true

# The reference runs after the system is stopped, so it takes nothing from it.
log "computing the reference"
python3 "${RANDOM_DIR}/lib/reference.py" load "${WORK}/data" "${WORK}/reference-db"
python3 "${RANDOM_DIR}/lib/reference.py" run "${WORK}/reference-db" "${PAYLOAD}/queries.json" \
    "${WORK}/reference" --timeout "${RANDOM_REFERENCE_TIMEOUT}"

log "validating"
python3 "${RANDOM_DIR}/lib/validate.py" "${WORK}/reference" "${WORK}/run"

python3 - "${WORK}" "${SYSTEM_DIR}" "${PAYLOAD}" "${load_time}" "${data_size}" "${data_size_after}" <<'EOF'
import json, os, sys
work, system_dir, payload, load_time, data_size, data_size_after = sys.argv[1:]
def number(x):
    try:
        return float(x) if "." in x else int(x)
    except ValueError:
        return None
run = json.load(open(os.path.join(work, "run", "run.json")))
validation = json.load(open(os.path.join(work, "run", "validation.json")))
reference = json.load(open(os.path.join(work, "reference", "status.json")))
template = json.load(open(os.path.join(system_dir, "template.json")))
translated = json.load(open(os.path.join(payload, "translated.json")))
checked = {(v["id"], v["repeat"]): v for v in validation["results"]}
executions = []
for e in run["executions"]:
    v = checked[(e["id"], e["repeat"])]
    executions.append({"id": e["id"], "repeat": e["repeat"], "status": v["status"], "detail": v["detail"],
                       "start": e["start"], "time": e["time"], "reported_time": e["reported_time"]})
# The beginning of the output of every query, for the inspection of wrong results.
outputs = {}
for e in run["executions"]:
    if e["repeat"] == 1 and e["status"] == "ok":
        with open(os.path.join(work, "run", "out", f"{e['id']}.1.out"), "rb") as f:
            outputs[e["id"]] = f.read(2000).decode(errors="replace")
# All the outputs (up to 64 KB each) and the reference results, compressed,
# so that the results can be validated again with a newer validator
# (collect-results.py does).
import base64, gzip
def pack(d):
    return base64.b64encode(gzip.compress(json.dumps(d, ensure_ascii=False).encode(), 9)).decode()
def read_outputs(repeats, limit):
    out = {}
    for e in run["executions"]:
        if e["status"] == "ok" and e["repeat"] in repeats:
            with open(os.path.join(work, "run", "out", f"{e['id']}.{e['repeat']}.out"), "rb") as f:
                out[f"{e['id']}.{e['repeat']}"] = f.read(limit).decode(errors="replace")
    return out
# The sink refuses too large rows: fewer repeats and shorter outputs until
# the compressed outputs fit into 600 KB.
for repeats, limit in ((range(1, 100), 65536), ((1,), 65536), ((1,), 16384), ((1,), 4096)):
    all_outputs = read_outputs(set(repeats), limit)
    if len(pack(all_outputs)) <= 600000:
        break
reference_outputs = {}
for qid, v in reference.items():
    if v["status"] == "ok":
        with open(os.path.join(work, "reference", qid + ".tsv"), "rb") as f:
            reference_outputs[qid] = f.read(65536).decode(errors="replace")
counts = validation["counts"]
total = sum(counts.values())
json.dump({
    "system": template.get("system"), "proprietary": template.get("proprietary"), "tuned": template.get("tuned"),
    "tags": template.get("tags", []), "directory": os.path.basename(system_dir),
    "rows": int(os.environ["RANDOM_ROWS"]), "seed": os.environ["RANDOM_SEED"],
    "clickhouse_version": os.environ["RANDOM_CLICKHOUSE_VERSION"],
    "parallel": run["parallel"], "repeats": run["repeats"], "query_timeout": run["timeout"],
    "load_time": number(load_time), "data_size": number(data_size), "data_size_after": number(data_size_after),
    "total_time": run["total_time"], "restarts": run["restarts"], "counts": counts,
    "error_rate": round(sum(n for s, n in counts.items() if s not in ("ok", "unverified")) / total, 4) if total else None,
    "translator": translated.get("translator"),
    "reference": {k: {"status": v["status"], "time": v["time"]} for k, v in reference.items()},
    "executions": executions, "outputs": outputs,
    "outputs_gz": pack(all_outputs), "reference_gz": pack(reference_outputs),
}, open(os.path.join(work, "result.json"), "w"), ensure_ascii=False)
print("Result: " + json.dumps(counts))
EOF
