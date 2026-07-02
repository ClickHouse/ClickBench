#!/usr/bin/env bash
# List the ClickHouse versions to benchmark, one per line, as:
#
#     <version>\t<image_ref>\t<release_date>
#
# The authoritative set of releases comes from ClickHouse's own
# version_date.tsv (oldest is 1.1.54011, 2016-08-18). Selection rules:
#   * keep ALL versions of the 1.1.x family;
#   * for calendar-versioned releases (18.x and newer), keep only the
#     latest patch within every major.minor (one per YY.MM line).
#
# Each selected version is resolved to a provider:
#   * yandex/clickhouse-server:<v>      historical images (1.1.x .. 21.x)
#   * clickhouse/clickhouse-server:<v>  modern images (20.x .. today)
#   * package                           no image, but a .deb/.tgz may exist
#                                        (runner installs it into Ubuntu)
#   * unavailable                       neither image nor package published
#                                        (e.g. the pre-1.1.54019 builds)
# We prefer the yandex image while it exists (<= 21.x) and clickhouse otherwise.
#
# The version_date.tsv and Docker tag lists are cached under prepare-data/data/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${HERE}/prepare-data/data"
mkdir -p "${CACHE}"

# --- authoritative release list (version + date) -------------------------------
VD="${CACHE}/version_date.tsv"
[ -s "${VD}" ] || curl -s "https://clickhouse.com/data/version_date.tsv" -o "${VD}"

# --- Docker tag lists for provider resolution ----------------------------------
fetch_tags() {
    local repo="$1" out="$2"
    [ -s "${out}" ] && return 0
    local token
    token=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        | grep -oE '"token":"[^"]+"' | sed 's/"token":"//;s/"//')
    curl -s -H "Authorization: Bearer ${token}" \
        "https://registry-1.docker.io/v2/${repo}/tags/list" \
        | tr ',' '\n' | grep -oE '"[^"]+"' | tr -d '"' > "${out}"
}
fetch_tags "yandex/clickhouse-server"     "${CACHE}/tags-yandex.txt"
fetch_tags "clickhouse/clickhouse-server" "${CACHE}/tags-clickhouse.txt"
YANDEX=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' "${CACHE}/tags-yandex.txt"     | sort -uV)
CLICKHOUSE=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$' "${CACHE}/tags-clickhouse.txt" | sort -uV)
has() { grep -qxF "$2" <<<"$1"; }

# Resolve an image for a version. version_date uses 4-component builds (19.1.16.79)
# while old images are often tagged with 3 (19.1.16), so fall back to the newest
# tag sharing the first three components. Echoes the image ref, or "" if none.
resolve_image() {
    local v="$1" major="${v%%.*}" v3 cand
    if [ "${major}" -le 21 ] 2>/dev/null && has "${YANDEX}" "${v}"; then
        echo "yandex/clickhouse-server:${v}"; return
    fi
    has "${CLICKHOUSE}" "${v}" && { echo "clickhouse/clickhouse-server:${v}"; return; }
    has "${YANDEX}"     "${v}" && { echo "yandex/clickhouse-server:${v}";     return; }
    v3="$(cut -d. -f1-3 <<<"${v}")"
    if [ "${major}" -le 21 ] 2>/dev/null; then
        cand=$(grep -E "^${v3//./\\.}(\.|$)" <<<"${YANDEX}" | tail -1)
        [ -n "${cand}" ] && { echo "yandex/clickhouse-server:${cand}"; return; }
    fi
    cand=$(grep -E "^${v3//./\\.}(\.|$)" <<<"${CLICKHOUSE}" | tail -1)
    [ -n "${cand}" ] && { echo "clickhouse/clickhouse-server:${cand}"; return; }
    echo ""
}

# --- normalise version_date.tsv to "version<TAB>date", version-sorted ----------
NORM=$(sed -E 's/^v//; s/-(stable|lts|testing|prestable)\t/\t/' "${VD}" \
       | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
       | grep -v '^1\.1\.54011[[:space:]]' \
       | sort -V)   # 1.1.54011 == bare tag 54011 (built from source); avoid the duplicate

# Versions we resurrect by building from source (build-from-source/versions.txt):
# their provider is the locally-built image clickhouse-built:<v>. This both
# overrides the "unavailable" 1.1.x releases and adds the bare-number early tags
# (53973..54011) that predate version_date.tsv.
BUILT_FILE="${HERE}/build-from-source/versions.txt"
declare -A BUILT_DATE=()
if [ -f "${BUILT_FILE}" ]; then
    while IFS=$'\t' read -r bv _btag bdate _bgcc; do
        [ -n "${bv}" ] && BUILT_DATE["${bv}"]="${bdate}"
    done < "${BUILT_FILE}"
fi

# Prehistoric monthly builds reconstructed from source
# (build-from-source/monthly-built.tsv): date-labeled YYYY-MM-01, each an image
# clickhouse-built:<month>. They predate version_date.tsv entirely (2012-04 .. 2016-02);
# months before 2012-04 have no server binary and are recorded as pre-server -- skip those.
# Commit dates come from monthly.tsv (its authoritative 3rd column).
MONTHLY_BUILT="${HERE}/build-from-source/monthly-built.tsv"
MONTHLY_TSV="${HERE}/build-from-source/monthly.tsv"
declare -A MONTH_DATE=()
if [ -f "${MONTHLY_TSV}" ]; then
    while IFS=$'\t' read -r m _sha mdate _rev; do
        [ -n "${m}" ] && MONTH_DATE["${m}"]="${mdate}"
    done < "${MONTHLY_TSV}"
fi

emit() {  # version date  -> resolve provider and print the line
    local v="$1" date="$2" image
    image="$(resolve_image "${v}")"
    if [ -z "${image}" ]; then
        # No image. packages.clickhouse.com ships .tgz from 21.1 on; older = gone.
        [ "${v%%.*}" -ge 21 ] 2>/dev/null && image="package" || image="unavailable"
    fi
    # Prefer a from-source build where we have one (resurrects the oldest), and
    # for built versions report the real commit date from versions.txt rather
    # than the version_date.tsv release date.
    if [ "${image}" = "unavailable" ] && [ -n "${BUILT_DATE[$v]:-}" ]; then
        image="clickhouse-built:${v}"
    fi
    [[ "${image}" == clickhouse-built:* ]] && date="${BUILT_DATE[$v]:-$date}"
    printf '%s\t%s\t%s\n' "${v}" "${image}" "${date}"
}

{
    # All 1.1.x are kept (including the handful with no image, so they are at
    # least listed/"found").
    grep -E $'^1\\.1\\.' <<<"${NORM}" | while IFS=$'\t' read -r v date; do
        emit "${v}" "${date}"
    done

    # Calendar releases: per major.minor, take the latest patch that resolves to
    # an actual image (falling back to an older patch in the same line if the
    # newest build has no image).
    grep -vE $'^1\\.1\\.' <<<"${NORM}" \
        | awk -F'\t' '{split($1,p,"."); print p[1]"."p[2]}' | sort -uV | while read -r key; do
        chosen=""
        while IFS=$'\t' read -r v date; do
            [ -n "$(resolve_image "${v}")" ] && { emit "${v}" "${date}"; chosen=1; break; }
            newest_v="${v}"; newest_d="${date}"
        done < <(awk -F'\t' -v k="${key}" '{split($1,p,"."); if (p[1]"."p[2]==k) print}' <<<"${NORM}" | sort -rV)
        if [ -z "${chosen}" ]; then emit "${newest_v}" "${newest_d}"; fi   # none runnable -> newest as unavailable
    done

    # Bare-number early tags (53973..54011) predate version_date.tsv; add them
    # directly with their from-source images.
    for bv in "${!BUILT_DATE[@]}"; do
        case "${bv}" in *.*) continue ;; esac   # skip the 1.1.x ones (handled above)
        printf '%s\tclickhouse-built:%s\t%s\n' "${bv}" "${bv}" "${BUILT_DATE[$bv]}"
    done

    # Prehistoric monthly builds (2012-06 .. 2016-02), reconstructed from source and
    # labeled by month. Skipped:
    #  * pre-server months (2012-01..03): no server binary at all.
    #  * 2012-04/05: the server boots but the era's client has no --query and its
    #    interactive/HTTP paths can't be scripted, so no query can run -- not benchmarkable.
    #    (2012-06 is the first month with a --query-capable client.)
    if [ -f "${MONTHLY_BUILT}" ]; then
        while IFS=$'\t' read -r m _sha note; do
            [ -z "${m}" ] && continue
            case "${note}" in pre-server*) continue ;; esac   # no server binary -> not runnable
            [[ "${m}" < "2012-06-01" ]] && continue           # no scriptable client -> not benchmarkable
            printf '%s\tclickhouse-built:%s\t%s\n' "${m}" "${m}" "${MONTH_DATE[$m]:-${m}}"
        done < "${MONTHLY_BUILT}"
    fi
} | sort -t$'\t' -k3,3 -k1,1V   # chronological by release date
