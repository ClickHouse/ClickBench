#!/usr/bin/env bash
# Benchmark a single ClickHouse version inside Docker.
#
#   ./run-version.sh <version> [image_ref] [phase]
#
# Spins up the server, creates the six tables with version-appropriate DDL
# (create/create.sh), loads the prepared Native files with a plain
# `clickhouse-client INSERT ... FORMAT Native`, then times every query in
# queries/{mgbench,ssb,hits,tpch,tpcds,coffeeshop,ontime,uk,job,taxi}.sql (TRIES runs each, dropping the page
# cache between queries) and writes results/<version>.json.
#
# phase (default "all") splits load from benchmark so run-all.sh can load many
# versions in parallel and then benchmark them one at a time:
#   load  - start the container and load data; LEAVE it running.
#   bench - attach to the already-loaded container, run queries, write the
#           result, then remove the container.
#   all   - load + bench + teardown in one go (single-version use).
#
# image_ref comes from list-versions.sh: either "<repo>/clickhouse-server:<v>"
# or the literal "package" (install the .deb into Ubuntu — fallback provider).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${DATA:-${HERE}/prepare-data/data}"
TRIES="${TRIES:-6}"   # 1 cold + 5 hot runs
MEM=100000000000   # 100G per-query memory limit
# How many datasets to load concurrently. Loading all of them at once can OOM-kill
# the server (and thus stop the container) on memory-hungry old versions; see load_data.
LOAD_PARALLEL="${LOAD_PARALLEL:-4}"
# Datasets to actually load. Queries for any skipped dataset still run (and
# report null). E.g. LOAD_DATASETS="hits ssb mgbench" skips the big taxi load
# while keeping its file on disk.
LOAD_DATASETS="${LOAD_DATASETS:-hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"

VERSION="${1:?usage: run-version.sh <version> [image_ref] [phase]}"
IMAGE="${2:-}"
PHASE="${3:-all}"
[ -z "${IMAGE}" ] && IMAGE="$(./list-versions.sh | awk -v v="${VERSION}" '$1==v{print $2}')"
[ -z "${IMAGE}" ] && { echo "no image for ${VERSION}" >&2; exit 1; }

# Prehistoric monthly reconstructions (date-labeled YYYY-MM-DD) can't meaningfully run the
# big/complex datasets -- the large multi-way joins (job, tpcds, tpch), the 600M-row SSB
# lineorder_flat, and the 500M-row coffeeshop fact -- which would only waste load time or
# crash. Never load those for prehistoric versions; their queries are recorded null as usual.
if [[ "${VERSION}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    _keep=""
    for _ds in ${LOAD_DATASETS}; do
        case "${_ds}" in ssb|tpch|tpcds|coffeeshop|job) continue ;; esac
        _keep+="${_ds} "
    done
    LOAD_DATASETS="${_keep% }"
    echo "prehistoric ${VERSION}: loading only [${LOAD_DATASETS}]; skipping ssb/tpch/tpcds/coffeeshop/job" >&2
fi

CONTAINER="chver_${VERSION//[^0-9A-Za-z]/_}"
OUT="${HERE}/results/${VERSION}.json"
# Per-table load timings, written during the load phase and read by the bench
# phase (which may be a separate invocation) to build the result's load_time.
LOAD_STATS="${HERE}/logs/${VERSION}.loadtimes.tsv"
mkdir -p "${HERE}/logs"

# Datasets => "table:file" pairs to create+load.
declare -A TABLES=(
    [hits]="hits:hits.native.zst"
    [ssb]="lineorder_flat:ssb.native.zst"
    [mgbench]="logs1:mgbench1.native.zst logs2:mgbench2.native.zst logs3:mgbench3.native.zst"
    [taxi]="trips:taxi.native.zst"
    [tpch]="nation:tpch_nation.native.zst region:tpch_region.native.zst part:tpch_part.native.zst supplier:tpch_supplier.native.zst partsupp:tpch_partsupp.native.zst customer:tpch_customer.native.zst orders:tpch_orders.native.zst lineitem:tpch_lineitem.native.zst"
    [tpcds]="call_center:tpcds_call_center.native.zst catalog_page:tpcds_catalog_page.native.zst catalog_returns:tpcds_catalog_returns.native.zst catalog_sales:tpcds_catalog_sales.native.zst customer_address:tpcds_customer_address.native.zst customer_demographics:tpcds_customer_demographics.native.zst customer:tpcds_customer.native.zst date_dim:tpcds_date_dim.native.zst household_demographics:tpcds_household_demographics.native.zst income_band:tpcds_income_band.native.zst inventory:tpcds_inventory.native.zst item:tpcds_item.native.zst promotion:tpcds_promotion.native.zst reason:tpcds_reason.native.zst ship_mode:tpcds_ship_mode.native.zst store_returns:tpcds_store_returns.native.zst store_sales:tpcds_store_sales.native.zst store:tpcds_store.native.zst time_dim:tpcds_time_dim.native.zst warehouse:tpcds_warehouse.native.zst web_page:tpcds_web_page.native.zst web_returns:tpcds_web_returns.native.zst web_sales:tpcds_web_sales.native.zst web_site:tpcds_web_site.native.zst"
    [coffeeshop]="fact_sales:coffeeshop_fact_sales.native.zst dim_locations:coffeeshop_dim_locations.native.zst dim_products:coffeeshop_dim_products.native.zst"
    [ontime]="ontime:ontime.native.zst"
    [uk]="uk_price_paid:uk_price_paid.native.zst"
    [job]="aka_name:job_aka_name.native.zst aka_title:job_aka_title.native.zst cast_info:job_cast_info.native.zst char_name:job_char_name.native.zst comp_cast_type:job_comp_cast_type.native.zst company_name:job_company_name.native.zst company_type:job_company_type.native.zst complete_cast:job_complete_cast.native.zst info_type:job_info_type.native.zst keyword:job_keyword.native.zst kind_type:job_kind_type.native.zst link_type:job_link_type.native.zst movie_companies:job_movie_companies.native.zst movie_info:job_movie_info.native.zst movie_info_idx:job_movie_info_idx.native.zst movie_keyword:job_movie_keyword.native.zst movie_link:job_movie_link.native.zst name:job_name.native.zst person_info:job_person_info.native.zst role_type:job_role_type.native.zst title:job_title.native.zst"
)
# Query files are run (and reported) in this fixed order. Each dataset loads
# into its own database (named after the dataset) so same-named tables (TPC-H
# and TPC-DS both have `customer`) don't collide.
#
# Order matters for resilience: a query that OOMs/crashes the server nulls not
# just itself but every query that runs before the server is revived. So the
# reliable, light datasets run FIRST and the heavy, crash-/timeout-prone ones
# (tpch, tpcds, job — big multi-way joins, INTERSECT, self-joins) run LAST, so a
# late crash can't take down the earlier datasets' results as collateral.
QUERY_ORDER="mgbench ssb hits uk ontime taxi coffeeshop tpch tpcds job"

cleanup() { sudo docker rm -f "${CONTAINER}" >/dev/null 2>&1; }
# The load phase must leave the container running for the later bench phase;
# all/bench tear it down on exit.
[ "${PHASE}" != "load" ] && trap cleanup EXIT

# Client dispatch. Modern/most images bundle a client (`exec` mode). The oldest
# server images (1.1.54xxx, early 18.x) ship only clickhouse-server, so we drive
# them with the matching-version client image as a sidecar sharing the server's
# network namespace (`sidecar` mode) — same native protocol, precise --time.
CLIENT_IMAGE="${IMAGE/-server/-client}"
CLIENT_MODE=""   # set by start_server: exec | sidecar
# CLIENT_BASIC=1 marks a prehistoric client that supports only the basic options (no
# --time / --format / --max_memory_usage); set by detect_client_caps, used by run_query.
CLIENT_BASIC=""
# Per-query memory-limit flag, decided at bench time (see run_benchmark). Set only for
# versions whose *effective* default max_memory_usage is 10 GB, so raising it lets their
# big queries finish. Modern versions default to 0 (unlimited) and lean on disk spill --
# forcing a limit there would defeat the spill and skew the result, so we leave it empty.
MEM_FLAG=""
# HOME=/tmp: old images set the clickhouse user's home to /nonexistent, so the
# client can't write its history file. TZ=UTC + the zoneinfo mount: some old
# client images ship no tzdata and otherwise fail at startup with "Could not
# determine local time zone" (before any query runs).
# CH_TIMEOUT (seconds), when set, wraps the client in `timeout` so a hung/slow
# query is killed after that long (the connection drop makes the server cancel
# it). Version-agnostic — no reliance on server-side settings that old builds
# may lack. Left empty for load/probe/version calls.
exec_client()    { sudo ${CH_TIMEOUT:+timeout ${CH_TIMEOUT}} docker exec -i -e HOME=/tmp -e TZ=UTC "${CONTAINER}" clickhouse client "$@"; }
sidecar_client() { sudo ${CH_TIMEOUT:+timeout ${CH_TIMEOUT}} docker run --rm -i -e HOME=/tmp -e TZ=UTC \
                       -v /usr/share/zoneinfo:/usr/share/zoneinfo:ro \
                       --network "container:${CONTAINER}" "${CLIENT_IMAGE}" "$@"; }
client() {
    case "${CLIENT_MODE}" in
        sidecar) sidecar_client "$@" ;;
        *)       exec_client "$@" ;;
    esac
}

# Existence check that works on EVERY version. The prehistoric clients/servers lack
# EXISTS TABLE / SHOW TABLES / DESCRIBE / system.tables, but a bare SELECT ... LIMIT 0
# succeeds iff the table exists (and errors "Unknown table" otherwise).
table_exists() { client --database "$1" --query "SELECT 1 FROM $2 LIMIT 0" </dev/null >/dev/null 2>&1; }

# Run a (possibly multi-statement, ;-separated) DDL script ONE statement at a time via
# --query. The prehistoric clients have no --multiquery, so a DROP;CREATE script sent that
# way throws UnknownOptionException. A failed DROP ... IF EXISTS is harmless; the call
# fails only if a CREATE statement fails. Reads the script on stdin.
run_ddl() {
    local db="$1" stmt rc=0
    while IFS= read -r -d ';' stmt; do
        case "${stmt}" in *[![:space:]]*) : ;; *) continue ;; esac   # skip blank/whitespace-only
        if ! client --database "${db}" --query "${stmt}" </dev/null; then
            case "${stmt}" in *[Cc][Rr][Ee][Aa][Tt][Ee]*) rc=1 ;; esac
        fi
    done
    return "${rc}"
}

# Versions with no published image (clickhouse-built:*) are compiled from source
# on the fly here, so the benchmark is self-contained (nothing is pulled from a
# registry). The build recipe is looked up by version: tagged / bare-number
# releases from build-from-source/versions.txt (Dockerfile.ubuntu1604), and the
# untagged monthly snapshots from build-from-source/monthly.tsv (reconstructed
# via Dockerfile.reconstruct).
ensure_built_image() {
    sudo docker image inspect "${IMAGE}" >/dev/null 2>&1 && return 0
    local bfs="${HERE}/build-from-source" rec tag gcc sha
    rec="$(awk -F'\t' -v v="${VERSION}" '$1==v{print; exit}' "${bfs}/versions.txt" 2>/dev/null)"
    if [ -n "${rec}" ]; then
        tag="$(cut -f2 <<<"${rec}")"; gcc="$(cut -f4 <<<"${rec}")"
        echo "building ${IMAGE} from source (tag ${tag:-v${VERSION}-stable}, gcc-${gcc:-5})" >&2
        bash "${bfs}/build.sh" "${VERSION}" "${tag:-v${VERSION}-stable}" "${gcc:-5}" >&2
        return $?
    fi
    local rev
    read -r sha rev < <(awk -F'\t' -v v="${VERSION}" '$1==v{print $2, $4; exit}' "${bfs}/monthly.tsv" 2>/dev/null)
    if [ -n "${sha}" ]; then
        # monthly.tsv column 4 is the per-month revision, interpolated between the dates
        # the DBMS_MIN_REVISION_WITH_* protocol defines appeared; the Dockerfile clamps
        # it up to the snapshot's own protocol floor. The server then reports 0.0.<rev>.
        echo "reconstructing ${IMAGE} from source (commit ${sha}, revision ${rev:-auto})" >&2
        sudo docker buildx build --progress=plain --load \
            --build-arg "TAG=${sha}" ${rev:+--build-arg "REVISION=${rev}"} \
            -t "${IMAGE}" -f "${bfs}/Dockerfile.reconstruct" "${bfs}" >&2
        return $?
    fi
    echo "no build recipe for ${VERSION} in versions.txt or monthly.tsv" >&2
    return 1
}

start_server() {
    cleanup
    if [ "${IMAGE}" = "package" ]; then
        # Fallback provider: install the .deb release into a stock Ubuntu image.
        echo "starting ${VERSION} via package-in-ubuntu fallback" >&2
        sudo docker run -d --name "${CONTAINER}" --ulimit nofile=262144:262144 ubuntu:22.04 \
            sleep infinity >/dev/null
        sudo docker exec "${CONTAINER}" bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq curl ca-certificates
            curl -fsSL 'https://packages.clickhouse.com/tgz/stable/clickhouse-common-static-${VERSION}-amd64.tgz' -o /tmp/c.tgz
            tar -xzf /tmp/c.tgz -C /tmp && /tmp/clickhouse-common-static-${VERSION}/install/doinst.sh
            curl -fsSL 'https://packages.clickhouse.com/tgz/stable/clickhouse-client-${VERSION}-amd64.tgz' -o /tmp/cl.tgz
            tar -xzf /tmp/cl.tgz -C /tmp && /tmp/clickhouse-client-${VERSION}/install/doinst.sh
            curl -fsSL 'https://packages.clickhouse.com/tgz/stable/clickhouse-server-${VERSION}-amd64.tgz' -o /tmp/cs.tgz
            tar -xzf /tmp/cs.tgz -C /tmp && /tmp/clickhouse-server-${VERSION}/install/doinst.sh --noninteractive
            clickhouse-server --daemon --config /etc/clickhouse-server/config.xml" >&2
    else
        echo "starting ${VERSION} from image ${IMAGE}" >&2
        if [[ "${IMAGE}" == clickhouse-built:* ]]; then
            ensure_built_image || { echo "failed to build ${IMAGE}" >&2; return 1; }
        else
            sudo docker pull "${IMAGE}" >/dev/null 2>&1
        fi
        # Mount an IPv4 listen override: old images default to listening on ::
        # (IPv6) and crash on boot when the host has IPv6 disabled.
        sudo docker run -d --name "${CONTAINER}" --ulimit nofile=262144:262144 \
            -v "${HERE}/config/listen.xml:/etc/clickhouse-server/config.d/zz-listen.xml:ro" \
            "${IMAGE}" >/dev/null
    fi
    # Wait for the server to accept queries, detecting the client mode: prefer
    # the bundled client; fall back to the sidecar client image for the oldest
    # server images that ship no client.
    [ "${IMAGE}" != "package" ] && [ -n "${CLIENT_IMAGE}" ] && \
        sudo docker pull "${CLIENT_IMAGE}" >/dev/null 2>&1
    local i
    for i in $(seq 1 "${READY_TIMEOUT:-90}"); do
        if exec_client --query "SELECT 1" >/dev/null 2>&1; then CLIENT_MODE=exec; return 0; fi
        if sidecar_client --query "SELECT 1" </dev/null >/dev/null 2>&1; then CLIENT_MODE=sidecar; return 0; fi
        sleep 1
    done
    echo "server ${VERSION} did not become ready; last container logs:" >&2
    sudo docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true
    return 1
}

# Load one dataset: create its database and (create+load) each of its tables.
# Tables that fail to create/load are left absent so their queries report null.
load_one_dataset() {
    local ds="$1" pair table file ddl t0 reader cnt
    # Each dataset lives in its own database so same-named tables (e.g. TPC-H
    # and TPC-DS `customer`) don't clash.
    client --query "CREATE DATABASE IF NOT EXISTS ${ds}" </dev/null 2>/dev/null
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; file="${pair##*:}"
        [ -f "${DATA}/${file}" ] || { echo "SKIP ${ds}.${table}: ${file} not present"; continue; }
        # Already loaded (a previous pass)? Skip, so the retry pass below only reloads
        # the tables that are actually missing rather than dropping and redoing them.
        if table_exists "${ds}" "${table}"; then
            cnt="$(client --database "${ds}" --query "SELECT count() FROM ${table}" 2>/dev/null | tr -d '\r')"
            [ -n "${cnt}" ] && [ "${cnt}" != "0" ] && { echo "already loaded ${ds}.${table} (${cnt} rows), skipping"; continue; }
        fi
        ddl="$("${HERE}/create/create.sh" "${VERSION}" "${ds}" "${table}")"
        echo "=== CREATE ${ds}.${table} on ${VERSION} ==="
        echo "${ddl}"
        # One statement at a time (no --multiquery on prehistoric clients).
        if ! printf '%s' "${ddl}" | run_ddl "${ds}"; then
            echo "CREATE ${ds}.${table} FAILED on ${VERSION}"; continue
        fi
        echo "=== INSERT INTO ${ds}.${table} FORMAT Native  <-  ${file} ($(du -h "${DATA}/${file}" | cut -f1)) ==="
        # Stream the compressed file through pv (progress %/rate/ETA once a
        # second, based on the known file size) -> zstd -dc -> a plain Native
        # INSERT, so the ancient clickhouse-client never sees compression.
        if command -v pv >/dev/null 2>&1; then
            reader=(pv -f -i 1 -N "${ds}.${table}" -- "${DATA}/${file}")
        else
            reader=(cat -- "${DATA}/${file}")
        fi
        t0=${SECONDS}
        if "${reader[@]}" | zstd -dc | client --database "${ds}" --query "INSERT INTO ${table} FORMAT Native"; then
            # Record this table's load time (small line -> atomic append, safe
            # across the parallel per-dataset jobs); summed per dataset at bench.
            printf '%s\t%s\n' "${ds}" "$((SECONDS - t0))" >> "${LOAD_STATS}"
            echo "loaded ${ds}.${table}: $(client --database "${ds}" --query "SELECT count() FROM ${table}" 2>/dev/null) rows in $((SECONDS - t0))s"
        else
            # An aborted INSERT (crash, OOM, disk full, interrupted stream) can leave
            # a partially-loaded table. Drop it so its queries report null rather than
            # timing against incomplete data.
            echo "LOAD ${ds}.${table} FAILED on ${VERSION}; dropping the incomplete table"
            client --database "${ds}" --query "DROP TABLE IF EXISTS ${table}" </dev/null 2>/dev/null
        fi
    done
}

# True if every table of this dataset whose source file is present exists on the server.
# Used by the load retry pass to decide what to reload.
dataset_loaded() {
    local ds="$1" pair table file
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; file="${pair##*:}"
        [ -f "${DATA}/${file}" ] || continue
        table_exists "${ds}" "${table}" || return 1
    done
    return 0
}

# Stricter: true only if EVERY table of the dataset is fully present -- its data file
# exists, the table exists, and it holds at least one row. If any table failed to load
# (dropped on failure, or empty), the dataset is not benchmarked and neither its load time
# nor its data size is reported. (An empty Log table's count() returns blank, so a table
# that did not load counts as not-loaded here.)
dataset_fully_loaded() {
    local ds="$1" pair table file cnt
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; file="${pair##*:}"
        [ -f "${DATA}/${file}" ] || return 1
        table_exists "${ds}" "${table}" || return 1
        cnt="$(client --database "${ds}" --query "SELECT count() FROM ${table}" 2>/dev/null | tr -d '\r')"
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

# Load the datasets, at most LOAD_PARALLEL at a time. Loading every dataset at once
# (10 background jobs, several of them multi-GB tables) can exhaust RAM on the older,
# less memory-efficient versions; earlyoom then kills clickhouse-server, and since it
# is the container's PID 1 the whole container stops, failing every in-flight load
# (that is exactly what corrupted 18.10.3's run). Bounding the concurrency keeps peak
# memory in check; a revive-and-retry pass then reloads anything that still failed,
# sequentially, so a transient death doesn't leave the dataset permanently missing.
load_data() {
    local ds pids=() active=0 to_load=() attempt missing
    : > "${LOAD_STATS}"   # fresh per run; per-table load times accumulate here
    for ds in ${LOAD_DATASETS}; do
        if ! dataset_supported "${ds}"; then
            echo "=== skipping load of ${ds}: no query supported on ${VERSION} (all below min version) ===" >&2
            continue
        fi
        to_load+=("${ds}")
    done

    for ds in "${to_load[@]}"; do
        load_one_dataset "${ds}" &
        pids+=("$!")
        active=$((active + 1))
        if [ "${active}" -ge "${LOAD_PARALLEL}" ]; then
            wait -n 2>/dev/null || wait "${pids[@]}"   # a slot frees when any job finishes
            active=$((active - 1))
        fi
    done
    wait

    # Retry pass: revive the server if it died and reload any dataset that is not fully
    # present, one at a time. load_one_dataset skips tables that already loaded, so this
    # only redoes the missing ones.
    for attempt in 1 2; do
        server_alive || revive_server || break
        missing=()
        for ds in "${to_load[@]}"; do dataset_loaded "${ds}" || missing+=("${ds}"); done
        [ "${#missing[@]}" -eq 0 ] && break
        echo "=== load retry ${attempt}: reloading sequentially: ${missing[*]} ===" >&2
        for ds in "${missing[@]}"; do
            server_alive || revive_server || break
            load_one_dataset "${ds}"
        done
    done
    echo "=== all dataset loads finished ==="
}

drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1; }

# </dev/null: the client runs via `docker {exec,run} -i`, which would otherwise
# read the caller's stdin — and the benchmark loop reads its query file on
# stdin, so a bare probe here would swallow the remaining queries.
server_alive() { client --query "SELECT 1" </dev/null >/dev/null 2>&1; }

# Bring the server back after a crash — best effort, several strategies in turn.
# A crash lands in one of two container states:
#   * container EXITED — clickhouse-server was PID 1 (most image providers) and the
#     OOM kill took it (and the container) down. `docker start` relaunches it with
#     the loaded tables intact.
#   * container still RUNNING — the server *process* died but PID 1 survived: the
#     package provider (PID 1 = sleep), or an image whose entrypoint is a wrapper
#     script that didn't exec the server. Here `docker start` is a no-op, so we
#     must relaunch the daemon *inside* the container.
# We try both, wait (a server re-attaching billions of rows of parts can take a
# while — hence a generous timeout), and fall back to a full `docker restart`.
# Every step is logged so a persistent failure is diagnosable from the run log.
launch_daemon_in_container() {
    sudo docker exec -d "${CONTAINER}" sh -c \
        'clickhouse-server --daemon --config /etc/clickhouse-server/config.xml 2>/dev/null \
         || clickhouse server --daemon --config /etc/clickhouse-server/config.xml 2>/dev/null \
         || clickhouse-server --config /etc/clickhouse-server/config.xml 2>/dev/null' 2>/dev/null || true
}
wait_alive() { local i; for i in $(seq 1 "${1:-180}"); do server_alive && return 0; sleep 1; done; return 1; }
revive_server() {
    local running
    running="$(sudo docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)"
    echo "${VERSION}: reviving server (container running=${running:-unknown}); recent container logs:" >&2
    sudo docker logs --tail 8 "${CONTAINER}" 2>&1 | sed 's/^/      | /' >&2 || true

    # Strategy 1: exited container -> start it back up.
    if [ "${running}" != "true" ]; then
        sudo docker start "${CONTAINER}" >/dev/null 2>&1 || echo "${VERSION}: 'docker start' failed" >&2
    fi
    # Strategy 2: container up but server process dead -> relaunch the daemon inside.
    if [ "$(sudo docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" = "true" ] && ! server_alive; then
        launch_daemon_in_container
    fi
    wait_alive "${REVIVE_TIMEOUT:-180}" && { echo "${VERSION}: server back up" >&2; return 0; }

    # Strategy 3 (last resort): force a full container restart, then relaunch the
    # daemon (needed for the package provider, whose PID 1 is sleep, not the server).
    echo "${VERSION}: still down after ${REVIVE_TIMEOUT:-180}s; forcing 'docker restart'" >&2
    sudo docker restart -t 5 "${CONTAINER}" >/dev/null 2>&1 || echo "${VERSION}: 'docker restart' failed" >&2
    server_alive || launch_daemon_in_container
    wait_alive "${REVIVE_TIMEOUT:-180}" && { echo "${VERSION}: server back up after restart" >&2; return 0; }

    echo "${VERSION}: could not revive server; final container logs:" >&2
    sudo docker logs --tail 30 "${CONTAINER}" 2>&1 | sed 's/^/      | /' >&2 || true
    return 1
}

# Report on-disk size per table: via system.parts, or (for old versions without
# it) by measuring the data directory inside the container, following symlinks.
report_sizes() {
    echo "=== table sizes on disk (${VERSION}) ==="
    local out
    # The benchmark tables live in per-dataset databases; exclude the server's
    # own system databases.
    out=$(client --query "SELECT database, table, sum(bytes_on_disk) AS size FROM system.parts WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') GROUP BY database, table ORDER BY database, table FORMAT TabSeparated" </dev/null 2>/dev/null)
    if [ -n "${out}" ]; then
        printf '%s\n' "${out}"
    else
        echo "(system.parts unavailable — measuring the data directory)"
        sudo docker exec "${CONTAINER}" sh -c '
            base=/var/lib/clickhouse; [ -d "$base/data" ] || base=/opt/clickhouse
            du -sLb "$base"/data/*/* 2>/dev/null | grep -vE "/data/system/" | sort -k2' 2>/dev/null \
            || echo "(could not measure data directory)"
    fi
}

# Collapse a (possibly multi-line) client error into one tidy, capped log line.
fmt_err() { printf '%s' "$1" | tr '\n\t' '  ' | sed 's/  */ /g; s/^ //' | cut -c1-800; }

# Version ordering across the whole timeline. Normalise any version we run to a
# 4-number key (major minor patch build):
#   * a bare build number (e.g. 53982) is a 2016 1.1.x snapshot -> 1.1.<n>.0
#   * 1.1.54378 / 20.5 / 26.6.1.1193 -> their dotted components (missing => 0)
# so 1.1.54378 and the bare 53982 both sort *below* any calendar release.
version_key() {
    local v="$1" a b c d
    if [[ "$v" =~ ^[0-9]+$ ]]; then echo "1 1 $v 0"; return; fi
    IFS='.' read -r a b c d _ <<<"$v"
    echo "${a:-0} ${b:-0} ${c:-0} ${d:-0}"
}
# version_ge A B  -> true if A >= B
version_ge() {
    local -a x y; read -ra x <<<"$(version_key "$1")"; read -ra y <<<"$(version_key "$2")"
    local i
    for i in 0 1 2 3; do
        [ "${x[i]}" -gt "${y[i]}" ] && return 0
        [ "${x[i]}" -lt "${y[i]}" ] && return 1
    done
    return 0
}
# A results row of all-null (used when a query is skipped as unsupported).
null_row() {
    local i out="["
    for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done
    echo "${out}]"
}
# Is any query of <dataset> runnable on the current VERSION? Reads the per-query
# minimum-version annotations (queries/<ds>.minver). Returns success if at least
# one query is supported ("0" or version >= its minver). When none are, the whole
# dataset is unsupported on this version, so there is no point loading it — every
# query would be recorded null anyway (see the skip logic in run_benchmark).
dataset_supported() {
    local ds="$1" mvf="${HERE}/queries/${ds}.minver" mv
    [ -f "${mvf}" ] || return 0   # no annotation -> assume supported
    while IFS= read -r mv; do
        [ -z "${mv}" ] && continue
        { [ "${mv}" = "0" ] || version_ge "${VERSION}" "${mv}"; } && return 0
    done < "${mvf}"
    return 1
}

# Run one query TRIES times, print a JSON array "[t1, ..., tN]" (null on error).
# The remaining tries are skipped (recorded null) once a try either:
#   * exceeds QUERY_TIMEOUT (default 100s) — no point re-timing a too-slow query, or
#   * crashes the server (e.g. OOM kill) — the server is revived so later queries
#     still run, but this query's remaining tries are abandoned.
# A plain error while the server stays up (e.g. a feature an old version lacks)
# just records null for that try and keeps going (every try will null anyway).
# Whatever the failure mode, the reason (and the server's error text, when there is
# one) is written to the log ONCE per query — tagged with the query's label — so a
# null in the results can be traced to an unsupported feature, a timeout or a crash.
run_query() {
    local query="$1" label="${2:-query}" i res rc out="[" skip_rest=0 logged=0 s e
    for i in $(seq 1 "${TRIES}"); do
        if [ "${skip_rest}" = 1 ]; then
            res="null"                     # an earlier try timed out or crashed; skip the rest
        else
            CH_TIMEOUT="${QUERY_TIMEOUT:-100}"
            if [ -n "${CLIENT_BASIC}" ]; then
                # Prehistoric client: no --time / --format / --max_memory_usage. Time the whole
                # invocation end to end and discard the output to /dev/null; on success res is
                # that elapsed time (matches the timing regex below), on error res is the
                # server's message (handled by the error branches).
                s=$(date +%s.%N)
                res=$(client --database "${QDB:-default}" --query "${query}" </dev/null 2>&1 >/dev/null)
                rc=$?
                e=$(date +%s.%N)
                [ "${rc}" = 0 ] && res=$(awk "BEGIN{printf \"%.3f\", ${e}-${s}}")
            else
                res=$(printf '%s' "${query}" | client --database "${QDB:-default}" --time ${MEM_FLAG} --format=Null 2>&1)
                rc=$?
            fi
            CH_TIMEOUT=""
            if [ "${rc}" = 124 ] || [ "${rc}" = 137 ]; then     # `timeout` killed it
                [ "${logged}" = 0 ] && echo "${label}: FAILED (timeout >${QUERY_TIMEOUT:-100}s); recording null, skipping remaining tries" >&2
                logged=1; skip_rest=1; res="null"
            elif [[ "${res}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                :                                               # good timing
            elif ! server_alive; then
                [ "${logged}" = 0 ] && echo "${label}: FAILED (server died mid-query, likely OOM); reviving, skipping remaining tries. Last output: $(fmt_err "${res}")" >&2
                logged=1; revive_server || true                 # restore it for the following queries
                skip_rest=1; res="null"
            else
                # Query errored but the server is up (e.g. unsupported syntax/function
                # on an old version). Record null and log the server's error message.
                [ "${logged}" = 0 ] && echo "${label}: FAILED (error): $(fmt_err "${res}")" >&2
                logged=1; res="null"
            fi
        fi
        out+="${res}"
        [ "${i}" -ne "${TRIES}" ] && out+=", "
    done
    echo "${out}]"
}

# Attach to an already-running, already-loaded container (bench phase): detect
# the client mode without (re)starting or wiping the container.
detect_client() {
    sudo docker ps -q -f "name=^${CONTAINER}$" | grep -q . || { echo "container ${CONTAINER} not running" >&2; return 1; }
    [ "${IMAGE}" != "package" ] && [ -n "${CLIENT_IMAGE}" ] && sudo docker pull "${CLIENT_IMAGE}" >/dev/null 2>&1
    local i
    for i in $(seq 1 30); do
        if exec_client --query "SELECT 1" >/dev/null 2>&1; then CLIENT_MODE=exec; return 0; fi
        if sidecar_client --query "SELECT 1" </dev/null >/dev/null 2>&1; then CLIENT_MODE=sidecar; return 0; fi
        sleep 1
    done
    return 1
}

# {"dataset": sum_of_table_load_seconds, ...} from the load phase (LOAD_STATS), restricted
# to the fully-loaded datasets ($1 = space-separated list): a dataset with any table that
# failed to load reports no load time at all.
emit_load_time_json() {
    local loaded=" ${1:-} "
    if [ -s "${LOAD_STATS}" ]; then
        awk -F'\t' -v loaded="${loaded}" 'index(loaded, " "$1" ")>0 {s[$1]+=$2}
            END{printf "{"; for(d in s){printf "%s\"%s\": %s",(n++?", ":""),d,s[d]}; printf "}"}' "${LOAD_STATS}"
    else
        printf '{}'
    fi
}

# {"dataset": on_disk_bytes, ...}: per-database sum of bytes_on_disk (each dataset is its
# own database). $1 = the fully-loaded datasets; a dataset with any table that failed to
# load reports no size. Prefer system.parts; for the prehistoric versions that lack it
# (added ~2014-08, and Log has no parts at all) measure the on-disk data directory instead.
emit_data_size_json() {
    local out loaded=" ${1:-} "
    out=$(client --query "SELECT database, sum(bytes_on_disk) FROM system.parts WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') GROUP BY database FORMAT TabSeparated" </dev/null 2>/dev/null)
    if [ -z "${out}" ]; then
        # No system.parts: sum the byte size of each dataset's data directory in the
        # container (works for both Log and MergeTree; -L follows the store/ symlinks).
        out=$(sudo docker exec "${CONTAINER}" sh -c '
            base=/var/lib/clickhouse; [ -d "$base/data" ] || base=/opt/clickhouse
            for d in "$base"/data/*/; do [ -d "$d" ] || continue; db=$(basename "$d");
                [ "$db" = system ] && continue
                printf "%s\t%s\n" "$db" "$(du -sLb "$d" 2>/dev/null | cut -f1)"; done' 2>/dev/null)
    fi
    printf '%s' "${out}" | awk -F'\t' -v loaded="${loaded}" 'BEGIN{printf "{"} NF>=2 && $2!="" && index(loaded, " "$1" ")>0 {printf "%s\"%s\": %s",(n++?", ":""),$1,$2} END{printf "}"}'
}

# Release date of this version, for the result JSON. list-versions.sh already
# resolves it (column 3) from the authoritative version_date.tsv for published and
# tagged source builds; the reconstructed monthly snapshots aren't in that list, so
# fall back to their commit date in monthly.tsv (column 3).
release_date() {
    local d
    d=$(./list-versions.sh 2>/dev/null | awk -F'\t' -v v="${VERSION}" '$1==v{print $3; exit}')
    [ -z "${d}" ] && d=$(awk -F'\t' -v v="${VERSION}" '$1==v{print $3; exit}' "${HERE}/build-from-source/monthly.tsv" 2>/dev/null)
    printf '%s' "${d}"
}

# Version string as reported by the running server. SELECT version() works from
# ~2015-07 on and returns 0.0.<revision> for the pre-release source builds (e.g.
# 0.0.53975). The oldest prehistoric builds have no version() function at all, so
# fall back to 0.0.<revision> using the revision compiled into the reconstructed
# image (baked at /clickhouse-revision by Dockerfile.reconstruct) -- which is exactly
# what those servers report in their TCP handshake.
server_version() {
    local v rev
    v=$(client --query "SELECT version()" 2>/dev/null | tr -d '\r')
    if [ -z "${v}" ]; then
        rev=$(sudo docker exec "${CONTAINER}" cat /clickhouse-revision 2>/dev/null | tr -d '\r\n ')
        [ -n "${rev}" ] && v="0.0.${rev}"
    fi
    printf '%s' "${v}"
}

# Time every query and write results/<version>.json.
run_benchmark() {
    local ACTUAL RELEASE ds query FIRST=1 qnum=0 row QDB MINVERS mv lidx ds_loaded FULLY_LOADED=""
    # Detect whether this version's client understands --time (and thus --format /
    # --max_memory_usage). The oldest reconstructed clients support only basic options, so
    # run_query times them externally instead.
    if client --query "SELECT 1" --time </dev/null >/dev/null 2>&1; then CLIENT_BASIC=""; else CLIENT_BASIC=1; fi
    echo "client capabilities on ${VERSION}: $([ -n "${CLIENT_BASIC}" ] && echo 'basic (external timing)' || echo 'full (--time/--format/--max_memory_usage)')" >&2
    # Raise the per-query memory limit ONLY where the effective default is 10 GB (the value
    # the old default-profile users.xml ships). Modern versions default to 0 (unlimited) and
    # spill to disk under memory pressure -- imposing a huge limit there defeats the spill.
    MEM_FLAG=""
    if [ -z "${CLIENT_BASIC}" ]; then
        local memdef
        memdef=$(client --query "SELECT value FROM system.settings WHERE name = 'max_memory_usage'" </dev/null 2>/dev/null | tr -d '[:space:]\r')
        [ "${memdef}" = "10000000000" ] && MEM_FLAG="--max_memory_usage=${MEM}"
        echo "server default max_memory_usage=${memdef:-unknown}; per-query override: ${MEM_FLAG:-none}" >&2
    fi
    ACTUAL=$(server_version)
    RELEASE=$(release_date)
    echo "benchmarking ${VERSION} (server reports ${ACTUAL:-unknown}, released ${RELEASE:-unknown})" >&2
    # Datasets that loaded in full. A dataset with even one table that failed to load is
    # not benchmarked (its queries record null) and reports neither load time nor size.
    for ds in ${QUERY_ORDER}; do
        if dataset_fully_loaded "${ds}"; then FULLY_LOADED+=" ${ds}";
        else echo "=== ${ds}: not fully loaded on ${VERSION}; skipping its queries, load time and size ===" >&2; fi
    done
    {
        echo '{'
        echo "    \"version\": \"${VERSION}\","
        echo "    \"actual_version\": \"${ACTUAL}\","
        echo "    \"release_date\": \"${RELEASE}\","
        echo "    \"load_time\": $(emit_load_time_json "${FULLY_LOADED}"),"
        echo "    \"data_size\": $(emit_data_size_json "${FULLY_LOADED}"),"
        echo '    "result":'
        echo '    ['
        for ds in ${QUERY_ORDER}; do
            QDB="${ds}"   # run this dataset's queries with its database as default
            # Skip a dataset that did not fully load: all its queries record null.
            case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
            # Per-query minimum supported version (queries/<ds>.minver, one token per
            # query, aligned to <ds>.sql): "0" = runs everywhere, a version = first
            # release known to run it, "26.7"(future) = never seen to succeed. When
            # the current version is below a query's minimum we record null WITHOUT
            # running it — the outcome is known and running it only wastes time (and
            # risks a crash that would null later queries too).
            MINVERS=(); [ -f "${HERE}/queries/${ds}.minver" ] && mapfile -t MINVERS < "${HERE}/queries/${ds}.minver"
            lidx=0
            # Read queries on FD 3 (not stdin) so the per-query `docker exec/run -i`
            # client calls can't consume the query file.
            while IFS= read -r query <&3; do
                [ -z "${query}" ] && continue
                query="${query%;}"                       # strip trailing semicolon
                qnum=$((qnum + 1))
                mv="${MINVERS[lidx]:-0}"; lidx=$((lidx + 1))
                if [ "${ds_loaded}" = 0 ]; then
                    row="$(null_row)"
                    echo "q${qnum} [${ds}]: SKIPPED (dataset not fully loaded); recording null" >&2
                elif [ "${mv}" != "0" ] && ! version_ge "${VERSION}" "${mv}"; then
                    row="$(null_row)"
                    echo "q${qnum} [${ds}]: SKIPPED (min supported ${mv}); recording null" >&2
                else
                    drop_caches
                    row="$(run_query "${query}" "q${qnum} [${ds}]")"
                    echo "q${qnum} [${ds}]: ${row}" >&2  # live timings to the log
                fi
                [ "${FIRST}" = 0 ] && echo ','
                FIRST=0
                printf '%s' "${row}"
            done 3< "${HERE}/queries/${ds}.sql"
        done
        echo
        echo '    ]'
        echo '}'
    } > "${OUT}"
    echo "wrote ${OUT}; result:" >&2
    cat "${OUT}"                                          # emit the JSON so it is captured/received
    report_sizes
}

# ---- run ----
case "${PHASE}" in
    load)
        start_server || exit 1
        echo "loading ${VERSION} ..." >&2
        load_data
        echo "loaded ${VERSION}; leaving container running for bench phase" >&2
        ;;
    bench)
        detect_client || { echo "cannot attach to ${VERSION} for bench" >&2; exit 1; }
        run_benchmark
        ;;
    all|*)
        start_server || exit 1
        load_data
        run_benchmark
        ;;
esac
