#!/usr/bin/env bash
# Benchmark ClickHouse inside Docker.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # collect statistics after loading (-> stats_time)
#
# The schema and queries come from explicit SQL files instead of being generated:
#
#   ddl/<benchmark>.sql       CREATE DATABASE + CREATE TABLE, hand-maintained
#   load/<benchmark>.sql      one INSERT ... SELECT FROM file() per table
#   queries/<benchmark>.sql   one query per line
#
# ../data IS local, so it is mounted read-only at /data and the server reads it itself 
# with file(). See load_one_dataset and config/user_files.xml.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"
TRIES="${TRIES:-6}"   # 1 cold + 5 hot runs
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
# Client-side receive timeout for LOAD-phase calls, in seconds. It is how long the client waits
# for the SERVER to send something before giving up.
#
# It bounds a SINGLE statement, not the whole load:
#     LOAD_TIMEOUT=7200 STATISTICS=1 ./run.sh
LOAD_TIMEOUT="${LOAD_TIMEOUT:-2400}"
# STATISTICS=1 materialises column statistics for every loaded table, so the optimiser can use
# them.
STATISTICS="${STATISTICS:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there -- no queries, and the server
# is LEFT RUNNING so you can drive it by hand.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a server that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1, and it is LEFT RUNNING afterwards.
#
# load_time is NOT measured by such a run. It is carried over from the last load.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi

SYSTEM="ClickHouse"
VERSION="26.7.5.10"
RELEASE_DATE="2026-08-21"   # release date of the pinned version, reported in the results
IMAGE="clickhouse/clickhouse-server:${VERSION}"
CONTAINER="dbbench_clickhouse"
CDATA="/data"   # where ${DATA} is mounted in the container; user_files_path points here
# Threads per server-side INSERT ... SELECT FROM file().
INSERT_THREADS="${INSERT_THREADS:-$(( $(nproc) / 4 ))}"
# One file per run: the timestamp keeps a run of one benchmark from erasing another benchmark's
# timings. generate-results.sh groups these by system and takes each benchmark's rows from the
# newest run that has them.
# The "machine" field of the results, which the page displays instead of naming a host in its own
# text -- so a report always describes the machine it was measured on. `uname -m` alone was
# useless: every x86 host reported "x86_64", which distinguishes nothing. The EC2 instance type
# comes from IMDSv2 when available; core count, RAM and root-volume size are read locally. Set
# MACHINE=... to override with anything the probe cannot see.
machine_label() {
    local tok itype cores ram disk
    tok=$(curl -sX PUT http://169.254.169.254/latest/api/token \
          -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' --max-time 2 2>/dev/null)
    itype=$(curl -s -H "X-aws-ec2-metadata-token: ${tok}" --max-time 2 \
            http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null)
    cores=$(nproc 2>/dev/null)
    ram=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
    disk=$(df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9')
    printf '%s, %s vCPU, %s GB RAM, %s GB disk' \
        "${itype:-$(uname -m)}" "${cores:-?}" "${ram:-?}" "${disk:-?}"
}
MACHINE="${MACHINE:-$(machine_label)}"

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${ROOT}/results/clickhouse/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/clickhouse/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/clickhouse.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/clickhouse.statstimes.tsv"
mkdir -p "${ROOT}/logs" "$(dirname "${OUT}")"

# Standard-SQL conformance settings.
SQL_COMPAT="--join_use_nulls=1 --group_by_use_nulls=1 --union_default_mode=DISTINCT
            --intersect_default_mode=DISTINCT --except_default_mode=DISTINCT
            --joined_subquery_requires_alias=0"
# No join spilling.
NO_SPILL="--max_bytes_ratio_before_external_join=0"
SETTINGS="${SQL_COMPAT} ${NO_SPILL}"

# Benchmarks to load. Queries for a skipped benchmark still run (and report null).
LOAD_DATASETS="${*:-tpch tpcds job}"
# Query files are run (and reported) in this fixed order, so a row's position in result[]
# identifies its query.
QUERY_ORDER="tpch tpcds job"

declare -A TABLES=(
    [tpch]="nation region part supplier partsupp customer orders lineitem"
    [tpcds]="call_center catalog_page catalog_returns catalog_sales customer_address customer_demographics customer date_dim household_demographics income_band inventory item promotion reason ship_mode store_returns store_sales store time_dim warehouse web_page web_returns web_sales web_site"
    [job]="aka_name aka_title cast_info char_name comp_cast_type company_name company_type complete_cast info_type keyword kind_type link_type movie_companies movie_info movie_info_idx movie_keyword movie_link name person_info role_type title"
)
declare -A QUERY_COUNT=([tpch]=22 [tpcds]=103 [job]=113)

for ds in ${LOAD_DATASETS}; do
    [ -n "${TABLES[$ds]:-}" ] || { echo "unknown benchmark: ${ds} (tpch | tpcds | job)" >&2; exit 1; }
done

cleanup() { sudo docker rm -fv "${CONTAINER}" >/dev/null 2>&1; }
trap cleanup EXIT

CH_TIMEOUT=""
client() {
    ${CH_TIMEOUT:+timeout ${CH_TIMEOUT}} sudo docker exec -i -e HOME=/tmp -e TZ=UTC \
        "${CONTAINER}" clickhouse client "$@"
}

table_exists() { client --database "$1" --query "SELECT 1 FROM $2 LIMIT 0" </dev/null >/dev/null 2>&1; }

# TPC-H is excluded on purpose: its spec declares every column NOT NULL, so it wants the
# default (non-nullable) and the setting would invert it.
ddl_flags_for() {
    case "$1" in tpcds|job) printf -- '--data_type_default_nullable=1' ;; *) printf '' ;; esac
}

# Run a (possibly multi-statement, ;-separated) DDL script ONE statement at a time via --query.
run_ddl() {
    local db="$1" extra="${2:-}" stmt rc=0
    while IFS= read -r -d ';' stmt; do
        case "${stmt}" in *[![:space:]]*) : ;; *) continue ;; esac
        if ! client --database "${db}" --query "${stmt}" ${extra} </dev/null; then
            case "${stmt}" in *[Cc][Rr][Ee][Aa][Tt][Ee]*) rc=1 ;; esac
        fi
    done
    return "${rc}"
}

start_server() {
    cleanup
    echo "starting ${VERSION} from image ${IMAGE}" >&2
    sudo docker pull "${IMAGE}" >/dev/null 2>&1
    # Mount an IPv4 listen override: the default listen host is :: (IPv6), which fails to
    # bind when the host has IPv6 disabled.
    # The data is mounted read-only and read SERVER-SIDE by file() (see load_one_dataset).
    # CLICKHOUSE_DO_NOT_CHOWN=1 is the image's own escape hatch -- its entrypoint sets
    # DO_CHOWN=0 when it is set -- and without it the entrypoint's `chown -R` over
    # user_files_path fails on the read-only mount and the container exits at once.
    sudo docker run -d --name "${CONTAINER}" --ulimit nofile=262144:262144 \
        -e CLICKHOUSE_DO_NOT_CHOWN=1 \
        -v "${DATA}:${CDATA}:ro" \
        -v "${HERE}/config/listen.xml:/etc/clickhouse-server/config.d/zz-listen.xml:ro" \
        -v "${HERE}/config/user_files.xml:/etc/clickhouse-server/config.d/zz-user-files.xml:ro" \
        "${IMAGE}" >/dev/null || return 1
    local i
    for i in $(seq 1 "${READY_TIMEOUT:-90}"); do
        server_alive && return 0
        sleep 1
    done
    echo "server ${VERSION} did not become ready; last container logs:" >&2
    sudo docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true
    return 1
}

# Load one benchmark: create its database and tables from ddl/, then run load/ -- one statement
# per table, each an INSERT ... SELECT FROM file(...) that the SERVER reads off the /data mount.
# Tables that fail to load are dropped so their queries report null rather than timing against
# incomplete data.
load_one_dataset() {
    local ds="$1" stmt file t0 table cnt
    client --query "CREATE DATABASE IF NOT EXISTS ${ds}" </dev/null 2>/dev/null
    echo "=== CREATE ${ds} tables ===" >&2
    if ! run_ddl "${ds}" "$(ddl_flags_for "${ds}")" < "${HERE}/ddl/${ds}.sql"; then
        echo "CREATE ${ds} FAILED" >&2; return 1
    fi
    # Read the load script on FD 3, not stdin: the `client` probes below run via
    # `sudo docker exec -i` and would otherwise consume the script itself (after the first table).
    while IFS= read -r stmt <&3; do
        case "${stmt}" in ''|--*) continue ;; esac
        stmt="${stmt%"${stmt##*[![:space:]]}"}"   # rtrim so the ';' below is actually last
        stmt="${stmt%;}"
        # Table name from the statement itself.
        table="${stmt##* INTO }"; table="${table%% *}"; table="${table#*.}"
        # The path inside the statement is the container's; map it back to the host to check that
        # it is there. A statement with no file() at all runs as-is.
        case "${stmt}" in
            *"file('"*)
                file="${stmt##*file(\'}"; file="${file%%\'*}"
                file="${DATA}${file#${CDATA}}"
                [ -f "${file}" ] || { echo "SKIP ${ds}.${table}: ${file} not present" >&2; continue; }
                ;;
            *)
                client --query "${stmt}" </dev/null || echo "${ds}: '${stmt}' failed; continuing" >&2
                continue
                ;;
        esac
        # Already loaded (a previous pass)? Skip, so the retry pass only reloads what is
        # actually missing rather than dropping and redoing everything.
        if table_exists "${ds}" "${table}"; then
            cnt="$(client --database "${ds}" --query "SELECT count() FROM ${table}" </dev/null 2>/dev/null | tr -d '\r')"
            [ -n "${cnt}" ] && [ "${cnt}" != "0" ] && { echo "already loaded ${ds}.${table} (${cnt} rows), skipping" >&2; continue; }
        fi
        echo "=== ${stmt}  ($(du -h "${file}" | cut -f1)) ===" >&2
        t0=${SECONDS}
        if client --database "${ds}" --max_insert_threads="${INSERT_THREADS}" \
                  --receive_timeout="${LOAD_TIMEOUT}" --query "${stmt}" </dev/null; then
            # Statistics are timed SEPARATELY, into STAT_STATS, and are NOT part of load_time.
            STATS_SECS=0
            if [ -n "${STATISTICS}" ]; then
                echo "=== MATERIALIZE STATISTICS ${ds}.${table} ===" >&2
                st0=${SECONDS}
                client --database "${ds}" --receive_timeout="${LOAD_TIMEOUT}" --query \
                    "ALTER TABLE ${table} MATERIALIZE STATISTICS ALL SETTINGS mutations_sync=1" \
                    </dev/null || echo "statistics on ${ds}.${table} failed; continuing" >&2
                STATS_SECS=$((SECONDS - st0))
                printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
                echo "statistics on ${ds}.${table}: ${STATS_SECS}s" >&2
            fi
            printf '%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" >> "${LOAD_STATS}"
            echo "loaded ${ds}.${table}: $(client --database "${ds}" --query "SELECT count() FROM ${table}" </dev/null 2>/dev/null) rows in $((SECONDS - t0 - STATS_SECS))s" >&2
        else
            # An aborted INSERT (crash, OOM, disk full, interrupted stream) can leave a
            # partially-loaded table. Drop it so its queries report null.
            echo "LOAD ${ds}.${table} FAILED; dropping the incomplete table" >&2
            client --database "${ds}" --query "DROP TABLE IF EXISTS ${table}" </dev/null 2>/dev/null
        fi
    done 3< <(sed -e "s#{{DATA}}#${CDATA}#g" "${HERE}/load/${ds}.sql")
}

# True if every table of this benchmark exists on the server.
dataset_loaded() {
    local ds="$1" table
    for table in ${TABLES[$ds]}; do table_exists "${ds}" "${table}" || return 1; done
    return 0
}

# Stricter: true only if EVERY table exists and holds at least one row. If any table failed to
# load, the benchmark is not benchmarked and neither its load time nor its size is reported.
dataset_fully_loaded() {
    local ds="$1" table cnt
    for table in ${TABLES[$ds]}; do
        table_exists "${ds}" "${table}" || return 1
        cnt="$(client --database "${ds}" --query "SELECT count() FROM ${table}" </dev/null 2>/dev/null | tr -d '\r')"
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

# Load the benchmarks one at a time.
load_data() {
    local ds attempt missing
    : > "${LOAD_STATS}"; : > "${STAT_STATS}"
    for ds in ${LOAD_DATASETS}; do
        load_one_dataset "${ds}"
    done
    for attempt in 1 2; do
        server_alive || revive_server || break
        missing=()
        for ds in ${LOAD_DATASETS}; do dataset_loaded "${ds}" || missing+=("${ds}"); done
        [ "${#missing[@]}" -eq 0 ] && break
        echo "=== load retry ${attempt}: reloading sequentially: ${missing[*]} ===" >&2
        for ds in "${missing[@]}"; do
            server_alive || revive_server || break
            load_one_dataset "${ds}"
        done
    done
    echo "=== all loads finished ===" >&2
}

# Drop the page cache so the first of the TRIES is genuinely cold rather than reading its own
# previous run's pages.
drop_caches() {
    [ "${DROP_CACHES}" = 0 ] && return 0
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
}

# Say once, at the start, what the cold column actually means in this run.
announce_cache_mode() {
    if [ "${DROP_CACHES}" = 0 ]; then
        echo "DROP_CACHES=0: page cache NOT dropped; the first of the ${TRIES} tries is not cold" >&2
    elif sudo -n true 2>/dev/null; then
        echo "page cache dropped before each query (${TRIES} tries: 1 cold + $((TRIES - 1)) hot)" >&2
    else
        echo "WARNING: no passwordless sudo, so the page cache cannot be dropped -- every one of" >&2
        echo "         the ${TRIES} tries is warm. Set DROP_CACHES=0 to make that explicit." >&2
    fi
}

server_alive() { client --query "SELECT 1" </dev/null >/dev/null 2>&1; }

launch_daemon_in_container() {
    sudo docker exec -d "${CONTAINER}" sh -c \
        'clickhouse-server --daemon --config /etc/clickhouse-server/config.xml' 2>/dev/null || true
}
wait_alive() { local i; for i in $(seq 1 "${1:-180}"); do server_alive && return 0; sleep 1; done; return 1; }
revive_server() {
    local running
    running="$(sudo docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)"
    echo "reviving server (container running=${running:-unknown}); recent container logs:" >&2
    sudo docker logs --tail 8 "${CONTAINER}" 2>&1 | sed 's/^/      | /' >&2 || true
    [ "${running}" != "true" ] && { sudo docker start "${CONTAINER}" >/dev/null 2>&1 || echo "'sudo docker start' failed" >&2; }
    if [ "$(sudo docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)" = "true" ] && ! server_alive; then
        launch_daemon_in_container
    fi
    wait_alive "${REVIVE_TIMEOUT:-180}" && { echo "server back up" >&2; return 0; }
    echo "still down after ${REVIVE_TIMEOUT:-180}s; forcing 'sudo docker restart'" >&2
    sudo docker restart -t 5 "${CONTAINER}" >/dev/null 2>&1 || echo "'sudo docker restart' failed" >&2
    server_alive || launch_daemon_in_container
    wait_alive "${REVIVE_TIMEOUT:-180}" && { echo "server back up after restart" >&2; return 0; }
    echo "could not revive server; final container logs:" >&2
    sudo docker logs --tail 30 "${CONTAINER}" 2>&1 | sed 's/^/      | /' >&2 || true
    return 1
}

# A results row of all-null, for a query that was never run.
null_row() {
    local i out="["
    for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done
    echo "${out}]"
}

# Run one query TRIES times, print a JSON array "[t1, ..., tN]" (null on error). The remaining
# tries are skipped once a try either exceeds QUERY_TIMEOUT (no point re-timing a too-slow
# query) or crashes the server (which is revived so later queries still run). A plain error
# while the server stays up just records null. Whatever the failure mode, the reason is written
# to the log ONCE per query, tagged with the query's label, so a null can be traced.
run_query() {
    local query="$1" label="${2:-query}" i res rc out="[" skip_rest=0 logged=0
    for i in $(seq 1 "${TRIES}"); do
        if [ "${skip_rest}" = 1 ]; then
            res="null"
        else
            CH_TIMEOUT="${QUERY_TIMEOUT}"
            res=$(printf '%s' "${query}" | client --database "${QDB:-default}" \
                  --time ${SETTINGS} --format=Null 2>&1)
            rc=$?
            CH_TIMEOUT=""
            if [ "${rc}" = 124 ] || [ "${rc}" = 137 ]; then
                [ "${logged}" = 0 ] && echo "${label}: FAILED (timeout >${QUERY_TIMEOUT}s); recording null, skipping remaining tries" >&2
                logged=1; skip_rest=1; res="null"
            elif [[ "${res}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                :
            elif ! server_alive; then
                [ "${logged}" = 0 ] && echo "${label}: FAILED (server died mid-query, likely OOM); reviving, skipping remaining tries. Last output: $(fmt_err "${res}")" >&2
                logged=1; revive_server || true
                skip_rest=1; res="null"
            else
                [ "${logged}" = 0 ] && echo "${label}: FAILED (error): $(fmt_err "${res}")" >&2
                logged=1; res="null"
            fi
        fi
        out+="${res}"
        [ "${i}" -ne "${TRIES}" ] && out+=", "
    done
    echo "${out}]"
}
fmt_err() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200; }

# {"benchmark": sum_of_table_load_seconds, ...}, restricted to the fully-loaded benchmarks
# ($1 = space-separated list): one that had any table fail reports no load time at all.
emit_load_time_json() {
    local loaded=" ${1:-} "
    if [ -s "${LOAD_STATS}" ]; then
        awk -F'\t' -v loaded="${loaded}" 'index(loaded, " "$1" ")>0 {s[$1]+=$2}
            END{printf "{"; for(d in s){printf "%s\"%s\": %s",(n++?", ":""),d,s[d]}; printf "}"}' "${LOAD_STATS}"
    else
        printf '{}'
    fi
}

# {"benchmark": seconds, ...}: time spent COLLECTING STATISTICS, per benchmark.
emit_stats_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${STAT_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${STAT_STATS}" || printf '{}'
}

# {"benchmark": on_disk_bytes, ...}: per-database sum of bytes_on_disk (each benchmark is its
# own database), restricted to the fully-loaded ones.
emit_data_size_json() {
    local out loaded=" ${1:-} "
    out=$(client --query "SELECT database, sum(bytes_on_disk) FROM system.parts WHERE active AND database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') GROUP BY database FORMAT TabSeparated" </dev/null 2>/dev/null)
    printf '%s' "${out}" | awk -F'\t' -v loaded="${loaded}" 'BEGIN{printf "{"} NF>=2 && $2!="" && index(loaded, " "$1" ")>0 {printf "%s\"%s\": %s",(n++?", ":""),$1,$2} END{printf "}"}'
}

server_version() { client --query "SELECT version()" </dev/null 2>/dev/null | tr -d '\r'; }

# Report on-disk size per table, from system.parts. The benchmark tables live in per-benchmark
# databases; the server's own system databases are excluded.
report_sizes() {
    echo "=== table sizes on disk (${VERSION}) ==="
    client --query "SELECT database, table, sum(bytes_on_disk) AS size FROM system.parts WHERE database NOT IN ('system', 'information_schema', 'INFORMATION_SCHEMA') GROUP BY database, table ORDER BY database, table FORMAT TabSeparated" </dev/null 2>/dev/null
}

# Time every query and write results/clickhouse.json.
run_benchmark() {
    local ACTUAL ds query FIRST=1 qnum=0 row QDB ds_loaded FULLY_LOADED="" n
    ACTUAL=$(server_version)
    echo "benchmarking ${SYSTEM} ${VERSION} (server reports ${ACTUAL:-unknown})" >&2
    # A benchmark with even one table that failed to load is not benchmarked: its queries
    # record null and it reports neither load time nor size.
    for ds in ${QUERY_ORDER}; do
        if dataset_fully_loaded "${ds}"; then FULLY_LOADED+=" ${ds}";
        else echo "=== ${ds}: not fully loaded; skipping its queries, load time and size ===" >&2; fi
    done
    {
        echo '{'
        echo "    \"system\": \"${SYSTEM}\","
        echo "    \"version\": \"${VERSION}\","
        echo "    \"actual_version\": \"${ACTUAL}\","
        echo "    \"release_date\": \"${RELEASE_DATE}\","
        echo "    \"machine\": \"${MACHINE}\","
        echo "    \"kind\": \"dbbench\","
        echo "    \"load_time\": $(emit_load_time_json "${FULLY_LOADED}"),"
        echo "    \"stats_time\": $(emit_stats_time_json "${FULLY_LOADED}"),"
        echo "    \"data_size\": $(emit_data_size_json "${FULLY_LOADED}"),"
        echo '    "result":'
        echo '    ['
        for ds in ${QUERY_ORDER}; do
            QDB="${ds}"   # run this benchmark's queries with its database as default
            case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
            n=0
            # Read queries on FD 3 (not stdin) so the per-query `sudo docker exec -i` client calls
            # cannot consume the query file.
            while IFS= read -r query <&3; do
                [ -z "${query}" ] && continue
                query="${query%;}"
                qnum=$((qnum + 1)); n=$((n + 1))
                if [ "${ds_loaded}" = 0 ]; then
                    row="$(null_row)"
                    echo "q${qnum} [${ds}]: SKIPPED (not loaded); recording null" >&2
                else
                    drop_caches
                    row="$(run_query "${query}" "q${qnum} [${ds}]")"
                    echo "q${qnum} [${ds}]: ${row}" >&2
                fi
                [ "${FIRST}" = 0 ] && echo ','
                FIRST=0
                printf '        %s' "${row}"
            done 3< "${HERE}/queries/${ds}.sql"
            # Keep result[] at its fixed length even if a query file is short.
            while [ "${n}" -lt "${QUERY_COUNT[$ds]}" ]; do
                [ "${FIRST}" = 0 ] && echo ','
                FIRST=0
                printf '        %s' "$(null_row)"
                n=$((n + 1))
            done
        done
        echo
        echo '    ]'
        echo '}'
    # Write to a temp file and rename: an interrupted run (Ctrl-C, a killed shell) would
    # otherwise leave a half-written results file behind, and generate-results.sh then fails to
    # parse it -- the run looks complete but the JSON is truncated mid-array.
    } > "${OUT}.tmp"
    mv "${OUT}.tmp" "${OUT}"
    echo "wrote ${OUT}" >&2
    # One-line report, so a single-system run says what it achieved without waiting for
    # run-all.sh's summary or generate-results.sh.
    python3 - "${OUT}" <<'SUMPY' >&2
import json, sys
d = json.load(open(sys.argv[1])); r = d["result"]
ran = lambda x: isinstance(x, list) and any(v is not None for v in x)
parts = [f'{n} {sum(1 for x in r[a:b] if ran(x))}/{b-a}' for n, a, b in
         (("tpch", 0, 22), ("tpcds", 22, 125), ("job", 125, 238))]
print(f'{d["system"]} {d["version"]}: ' + '  '.join(parts) +
      f'   load_time {d.get("load_time") or {}}')
SUMPY
    report_sizes
}

# ---- run ----
announce_cache_mode
if [ -n "${QUERY_ONLY}" ]; then
    trap - EXIT                       # this run did not start it, so it must not tear it down
    server_alive || {
        echo "QUERY_ONLY=1, but the ClickHouse server is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "server left running (this run did not start it). Tear down with:" >&2
    echo "    sudo docker rm -fv ${CONTAINER}" >&2
    exit 0
fi

start_server || exit 1
load_data
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "server left running. Connect with:" >&2
    echo "    docker exec -it ${CONTAINER} clickhouse client --database <benchmark>" >&2
    echo "Tear down with: sudo docker rm -fv ${CONTAINER}" >&2
    exit 0
fi
run_benchmark
