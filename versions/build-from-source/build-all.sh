#!/usr/bin/env bash
# Build every version listed in versions.txt from source (skipping ones whose
# image already exists). Up to JOBS builds run concurrently — these old, small
# codebases don't saturate the cores with a single `make -j$(nproc)`, so several
# builds in parallel fill the machine. Each build still uses make -j$(nproc).
#
#   ./build-all.sh            # build all in versions.txt
#   ./build-all.sh 53973 ...  # build only the given versions
#   JOBS=8 ./build-all.sh     # 8 concurrent builds (default 6)
#
# versions.txt is "<version><TAB><git-tag>[<TAB>date]" per line.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="${HERE}/logs"; mkdir -p "${LOGS}"
JOBS="${JOBS:-6}"

declare -A WANT=()
for a in "$@"; do WANT["$a"]=1; done

build_one() {  # version tag gcc
    local version="$1" tag="$2" gcc="${3:-5}"
    if sudo docker image inspect "clickhouse-built:${version}" >/dev/null 2>&1; then
        echo "skip ${version}: image exists"; return
    fi
    if bash "${HERE}/build.sh" "${version}" "${tag}" "${gcc}" >"${LOGS}/build-${version}.log" 2>&1; then
        echo "OK ${version}"
    else
        echo "FAILED ${version} (see ${LOGS}/build-${version}.log)" >&2
    fi
}

echo "building from versions.txt with up to ${JOBS} concurrent builds"
while IFS=$'\t' read -r version tag _date gcc; do
    [ -z "${version}" ] && continue
    [ "$#" -gt 0 ] && [ -z "${WANT[$version]:-}" ] && continue
    # Throttle to JOBS concurrent build_one jobs.
    while [ "$(jobs -rp | wc -l)" -ge "${JOBS}" ]; do wait -n 2>/dev/null || sleep 2; done
    build_one "${version}" "${tag}" "${gcc:-5}" &
done < "${HERE}/versions.txt"
wait
echo "build-all done"
