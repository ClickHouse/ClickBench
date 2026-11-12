# Sourced by the scripts of the randomized benchmark.
#
#   RANDOM_DIR         the random/ directory
#   RANDOM_CLICKHOUSE  the pinned ClickHouse binary that generates the data and
#                      computes the reference results. It is kept apart from
#                      whatever ClickHouse a benchmarked system installs.

RANDOM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLICKBENCH_DIR="$(cd "${RANDOM_DIR}/.." && pwd)"
: "${RANDOM_CLICKHOUSE:=/opt/random/clickhouse}"
export TZ=UTC

# The command line flags for the reference settings.
reference_settings() {
    grep -v '^#' "${RANDOM_DIR}/lib/reference-settings" | grep . | sed 's/^/--/'
}

# The structure of the table with the types of clickhouse/create.sql
# (DateTime, Date), as `name Type, ...`. The obfuscator needs these: given the
# integers of hits.parquet, it would scramble the times.
logical_structure() {
    { sed 's/CREATE OR REPLACE TABLE/CREATE TABLE/' "${CLICKBENCH_DIR}/clickhouse/create.sql"
      echo
      echo "SELECT arrayStringConcat(groupArray(name || ' ' || type), ', ') FROM system.columns
            WHERE database = currentDatabase() AND table = 'hits' FORMAT TSVRaw;"
    } > "${TMPDIR:-/tmp}/random-describe.$$.sql"
    "${RANDOM_CLICKHOUSE}" local --queries-file "${TMPDIR:-/tmp}/random-describe.$$.sql"
    rm -f "${TMPDIR:-/tmp}/random-describe.$$.sql"
}

# Downloads the pinned ClickHouse release for this architecture.
install_random_clickhouse() {
    local version="$1"
    [ -x "${RANDOM_CLICKHOUSE}" ] && return 0
    local arch
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) echo "unsupported architecture $(uname -m)" >&2; return 1 ;;
    esac
    # version is a release tag without the "v", e.g. 26.10.2.103-stable.
    local dir tmp
    dir="$(dirname "${RANDOM_CLICKHOUSE}")"
    tmp="$(mktemp -d)"
    curl -sSfL --retry 5 "https://github.com/ClickHouse/ClickHouse/releases/download/v${version}/clickhouse-common-static-${version%-*}-${arch}.tgz" \
        | tar xz -C "${tmp}" --strip-components=3 "clickhouse-common-static-${version%-*}/usr/bin/clickhouse"
    sudo mkdir -p "${dir}"
    sudo mv "${tmp}/clickhouse" "${RANDOM_CLICKHOUSE}"
    rm -rf "${tmp}"
    "${RANDOM_CLICKHOUSE}" --version
}
