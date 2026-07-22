#!/usr/bin/env bash
# Run the Versions Benchmark across many versions.
#
#   ./run-all.sh                       # all runnable versions from list-versions.sh
#   ./run-all.sh 1.1.54378 24.8.1.1    # only the given versions
#
# Versions are processed in batches of PARALLEL (default 32). Within a batch the
# slow, I/O-bound data LOAD runs in all containers concurrently; then the
# benchmark runs one container at a time so query timings are not contended.
# Each benched container is removed before its slot is reused, so peak disk use
# is ~PARALLEL copies of the loaded datasets — lower PARALLEL if disk is tight.
#
# Prepared Native files must already exist (see prepare-data/prepare.sh).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
PARALLEL="${PARALLEL:-32}"
LOGS="${HERE}/logs"; mkdir -p "${LOGS}"

# Resolve "version<TAB>image" rows (skip the unavailable builds).
ALL="$(./list-versions.sh)"
if [ "$#" -gt 0 ]; then
    LIST="$(for v in "$@"; do awk -F'\t' -v V="${v}" '$1==V{print $1"\t"$2}' <<<"${ALL}"; done)"
else
    LIST="$(awk -F'\t' '$2!="unavailable"{print $1"\t"$2}' <<<"${ALL}")"
fi
mapfile -t ROWS <<<"${LIST}"
TOTAL="${#ROWS[@]}"
[ "${TOTAL}" -eq 0 ] && { echo "no runnable versions" >&2; exit 1; }
echo "benchmarking ${TOTAL} versions, ${PARALLEL} loaded in parallel per batch"

for (( i=0; i<TOTAL; i+=PARALLEL )); do
    BATCH=( "${ROWS[@]:i:PARALLEL}" )
    n=$(( i/PARALLEL + 1 ))
    echo "######## batch ${n}: loading ${#BATCH[@]} versions in parallel ########"
    pids=()
    for row in "${BATCH[@]}"; do
        v="${row%%$'\t'*}"; img="${row#*$'\t'}"
        ./run-version.sh "${v}" "${img}" load </dev/null >"${LOGS}/load-${v}.log" 2>&1 &
        pids+=( "$!" )
    done
    wait "${pids[@]}" 2>/dev/null || true

    echo "######## batch ${n}: benchmarking ${#BATCH[@]} versions sequentially ########"
    for row in "${BATCH[@]}"; do
        v="${row%%$'\t'*}"; img="${row#*$'\t'}"
        echo "-------- ${v} (${img}) --------"
        ./run-version.sh "${v}" "${img}" bench </dev/null || echo "FAILED: ${v}" >&2
    done
done
echo "all batches done"
