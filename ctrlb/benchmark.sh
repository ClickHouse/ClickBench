#!/bin/bash
#
# ClickBench entry point for CtrlB (Parquet, single). Sets the harness env vars,
# runs the shared ClickBench driver, then turns its output into
# results/<UTC date>/<machine>.json — so one ./benchmark.sh yields a result file
# you can read exactly like the other engines' (see make-result.py).

export BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"
export BENCH_RESTARTABLE=yes
export BENCH_DURABLE=yes
export BENCH_TRIES="${BENCH_TRIES:-3}"

export BENCH_CONCURRENT_DURATION="${BENCH_CONCURRENT_DURATION:-0}"

# Run the shared ClickBench driver, capturing stdout so we can BOTH show it live
# and turn it into the committed results JSON. `tee` preserves the standard text
# output (Load time / [t1,t2,t3] / Data size); PIPESTATUS keeps the driver's real
# exit code (tee's is always 0).
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${CTRLB_RESULT_LOG:-$HERE/run.log}"

../lib/benchmark-common.sh | tee "$LOG"
status=${PIPESTATUS[0]}

# Assemble results/<UTC date>/c6a.4xlarge.json from the captured log + template.json,
# so the result is readable exactly like the other engines'. Non-fatal: if this
# can't run, the raw log ($LOG) is still there to convert by hand with
# make-result.py.
if [ "$status" -ne 0 ]; then
  echo "WARN: benchmark driver exited $status — not writing results JSON." >&2
elif ! command -v python3 > /dev/null 2>&1; then
  echo "WARN: python3 not found — run: python3 make-result.py \"$LOG\"" >&2
else
  python3 "$HERE/make-result.py" "$LOG" --machine "${CTRLB_MACHINE:-c6a.4xlarge}" \
    || echo "WARN: results JSON not written; run: python3 make-result.py \"$LOG\"" >&2
fi

exit "$status"
