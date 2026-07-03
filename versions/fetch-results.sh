#!/bin/bash -e

# Fetch the latest Versions Benchmark result for every version from the sink database
# (sink.data, rows with kind = "versions-benchmark", sent by cloud-init.sh.in) and write
# results/<version>.json, enriched with the release date. The committed result files are
# produced solely by this script -- do not edit them by hand.
#
# Connection settings come from $CONNECTION_PARAMS, as in the repo's collect-results.sh:
#   CONNECTION_PARAMS='--user check_benchmark_results --password *** --host play.clickhouse.com --secure' \
#       ./fetch-results.sh
#
# Then regenerate the page data with ./generate-results.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${HERE}"
CH() { clickhouse-client ${CONNECTION_PARAMS} "$@"; }

mkdir -p results

# Release-date lookup. list-versions.sh resolves it (column 3) for published and tagged
# builds from the authoritative version_date.tsv; the reconstructed monthly snapshots are
# not in that list, so fall back to their commit date in build-from-source/monthly.tsv.
LV="$(./list-versions.sh 2>/dev/null || true)"

# For calendar versions (18.x onwards) the page groups by YY.MM (major.minor). Use the
# date of the FIRST release in that YY.MM line so the group sorts/displays by when the
# release series began, not by the latest patch. GROUP_FIRST maps "YY.MM" -> earliest
# date, computed from the full release list in version_date.tsv.
VD="prepare-data/data/version_date.tsv"
declare -A GROUP_FIRST
if [ -s "${VD}" ]; then
    while IFS=$'\t' read -r mm d; do GROUP_FIRST["${mm}"]="${d}"; done < <(
        awk -F'\t' '{ v=$1; sub(/^v/,"",v); n=split(v,a,".");
            if (n>=2) { k=a[1]"."a[2]; if (!(k in m) || $2 < m[k]) m[k]=$2 } }
            END { for (k in m) print k"\t"m[k] }' "${VD}")
fi

reldate() {
    local v="$1" d mm
    if [[ "${v}" =~ ^([0-9]+)\.([0-9]+)\. ]] && [ "${BASH_REMATCH[1]}" -ge 18 ]; then
        mm="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
        [ -n "${GROUP_FIRST[$mm]:-}" ] && { printf '%s' "${GROUP_FIRST[$mm]}"; return; }
    fi
    d="$(awk -F'\t' -v v="$v" '$1==v{print $3; exit}' <<<"${LV}")"
    [ -z "${d}" ] && d="$(awk -F'\t' -v v="$v" '$1==v{print $3; exit}' build-from-source/monthly.tsv 2>/dev/null)"
    printf '%s' "${d}"
}

mapfile -t VERSIONS < <(CH --query "
    SELECT DISTINCT JSONExtractString(content, 'version') AS v
    FROM sink.data
    WHERE JSONExtractString(content, 'kind') = 'versions-benchmark' AND v != ''
      AND length(JSONExtractArrayRaw(content, 'result')) = 344
    ORDER BY v
    FORMAT TSV")

echo "fetching ${#VERSIONS[@]} versions from the sink" >&2
rm -f results/*.json
for v in "${VERSIONS[@]}"; do
    [ -z "${v}" ] && continue
    # argMax over time keeps the most recent run for this version.
    CH --query "
        SELECT argMax(content, time) FROM sink.data
        WHERE JSONExtractString(content, 'kind') = 'versions-benchmark'
          AND JSONExtractString(content, 'version') = '${v}'
          AND length(JSONExtractArrayRaw(content, 'result')) = 344
        FORMAT TSVRaw" > /tmp/vb-content.json
    # Skip runs whose data load did not complete: an OOM during the (parallel) load can
    # kill the server mid-INSERT and take the container down, leaving data_size null
    # and/or the big datasets unloaded (this is what repeatedly corrupted 18.10.3,
    # 1.1.54310/54327, 53989/53990 -- all from runs before the loader was fixed to bound
    # concurrency + retry). hits loads on every version, so a missing hits load time is a
    # reliable "incomplete run" signal. Such versions are simply left out until re-run.
    if jq -e '(.data_size == null) or (.load_time.hits == null)' /tmp/vb-content.json >/dev/null 2>&1; then
        echo "  SKIP ${v}: incomplete load (data_size/hits missing) -- re-run needed" >&2
        continue
    fi
    rd="$(reldate "${v}")"
    # Keep the recorded fields; add release_date (preferring one already in the payload).
    # Compact one line per file: these are generated artifacts, kept small in git.
    # Prefer a non-empty release_date already in the payload; otherwise use the looked-up
    # one (reldate). Note jq's // only defaults on null, not on an empty string, so an empty
    # payload release_date (what run-version.sh writes when it couldn't resolve a date) must
    # be handled explicitly -- else it would shadow the value we just resolved here.
    jq -cS --arg rd "${rd}" \
        '. + {release_date: (if (.release_date // "") != "" then .release_date
                             elif $rd != "" then $rd else null end)}' \
        /tmp/vb-content.json > "results/${v}.json"
    echo "  results/${v}.json (released ${rd:-unknown})" >&2
done
echo "wrote $(ls results/*.json 2>/dev/null | wc -l) result files" >&2

# Name files without a dotted version prefix (bare revision-number tag builds such as
# 53996) after their server-reported actual_version (1.1.53996), so every committed file
# is named by a real version. Several consecutive tag builds can report the same version
# (the revision wasn't bumped every tag), so dedupe by keeping the highest tag -- it is
# the one matching the reported revision -- and set that file's version field to match.
declare -A best
for f in results/*.json; do
    v="$(basename "${f}" .json)"
    case "${v}" in [0-9]*.[0-9]*|master) continue ;; esac   # dotted prefix, or the master tip: keep as-is
    av="$(jq -r '.actual_version // empty' "${f}")"; [ -z "${av}" ] && continue
    if [ -z "${best[${av}]:-}" ] || [ "${v}" -gt "${best[${av}]}" ]; then best[${av}]="${v}"; fi
done
for f in results/*.json; do
    v="$(basename "${f}" .json)"
    case "${v}" in [0-9]*.[0-9]*|master) continue ;; esac
    av="$(jq -r '.actual_version // empty' "${f}")"; [ -z "${av}" ] && continue
    if [ "${v}" = "${best[${av}]}" ]; then
        jq -cS --arg av "${av}" '.version = $av' "${f}" > results/.rename.tmp
        rm -f "${f}"; mv results/.rename.tmp "results/${av}.json"
        echo "  renamed ${v}.json -> ${av}.json" >&2
    else
        rm -f "${f}"; echo "  dropped ${v}.json (duplicate of ${av})" >&2
    fi
done

# Normalise every result to the current per-query minimum versions (queries/*.minver):
# the sink stores what each version produced under the minvers in effect WHEN it ran, which
# may predate the current ones, so re-apply them here for consistency (idempotent).
python3 "${HERE}/apply-minvers.py"
