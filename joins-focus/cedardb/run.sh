#!/usr/bin/env bash
# Benchmark CedarDB inside Docker. CedarDB speaks the PostgreSQL wire protocol, so every
# statement goes through psql -- run from a throwaway postgres client container over the host
# network, which is why the host itself needs no psql.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # ANALYZE after loading (reported as stats_time)
#
# Schema and queries come from explicit SQL files instead of being generated:
#
#   ddl/<benchmark>.sql       CREATE SCHEMA + CREATE TABLE ... PRIMARY KEY, hand-maintained
#   load/<benchmark>.sql      one INSERT ... SELECT * FROM '<file>.parquet' per table
#   queries/<benchmark>.sql   one query per line, unqualified table names (see search_path)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"
CDATA="/data"                                   # where DATA is bind-mounted in the container
TRIES="${TRIES:-6}"                             # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1200}"            # per-statement load cap (server-side + client backstop)
# STATISTICS=1 runs one ANALYZE per loaded table (see load_one_dataset).
STATISTICS="${STATISTICS:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a server that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

SYSTEM="CedarDB"
VERSION="v2026-08-20"
RELEASE_DATE="2026-08-20"   # release date of the pinned version, reported in the results
IMAGE="cedardb/cedardb:${VERSION}"
CONTAINER="dbbench_cedardb"
# Must satisfy the password policy CedarDB enforces from v2026-08-20 on.
PASSWORD="Cedarbench1!"
# One file per run, never overwritten.
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
OUT="${ROOT}/results/cedardb/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/cedardb/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/cedardb.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/cedardb.statstimes.tsv"
mkdir -p "${ROOT}/logs" "$(dirname "${OUT}")"

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
SIZE_LIMIT_HIT=0

# psql over the host network from a throwaway client container. PG() runs one statement,
# tuples-only; PGscript() pipes a full script from stdin.
PG()       { docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
                psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 -tAc "$1" 2>&1; }
PGscript() { timeout -k 10 "$((LOAD_TIMEOUT + 60))" docker run --rm -i --network host \
                -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
                psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 2>&1; }
# PGload: a load statement bounded server-side (statement_timeout) and by a client backstop, so a
# stuck load can't hang the whole run.
PGload() { timeout -k 10 "$((LOAD_TIMEOUT + 60))" docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" \
                "${PSQL_IMAGE}" psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 \
                -tAc "SET statement_timeout=${LOAD_TIMEOUT}000; $1" 2>&1; }

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

start_server() {
    docker rm -fv "${CONTAINER}" >/dev/null 2>&1
    mkdir -p "${DATA}"
    echo "starting ${SYSTEM} ${VERSION} (${IMAGE})" >&2
    docker run -d --name "${CONTAINER}" -e CEDAR_PASSWORD="${PASSWORD}" -p 5432:5432 \
        -v "${DATA}:${CDATA}:ro" "${IMAGE}" >/dev/null || return 1
    local waited=0
    until PG 'SELECT 1' 2>/dev/null | grep -q '^1$'; do
        sleep 3; waited=$((waited + 3))
        [ "${waited}" -gt 300 ] && { echo "CedarDB did not come up in 300s; last container logs:" >&2
                                     docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true; return 1; }
    done
    echo "CedarDB up ($(PG 'SELECT version()' 2>/dev/null | head -1))" >&2
}

# A heavy query can crash/OOM the CedarDB server (the container exits); restart down server.
ensure_up() {
    PG 'SELECT 1' 2>/dev/null | grep -q '^1$' && return 0
    echo "CedarDB ${VERSION} unreachable -- restarting the container" >&2
    docker start "${CONTAINER}" >/dev/null 2>&1
    local waited=0
    until PG 'SELECT 1' 2>/dev/null | grep -q '^1$'; do
        sleep 3; waited=$((waited + 3))
        [ "${waited}" -gt 120 ] && { echo "restart failed; recreating" >&2; start_server; return $?; }
    done
    return 0
}

stop_server() { docker rm -fv "${CONTAINER}" >/dev/null 2>&1; }

# CedarDB Community Edition caps total data size; exceeding it puts the DB in readonly mode.
size_limit_hit() { printf '%s' "$1" | grep -qiE 'size limit|readonly'; }

# Create one benchmark's schema and tables from ddl/<benchmark>.sql, in a single psql session.
run_ddl() {
    local ds="$1" out
    out=$(PGscript < "${HERE}/ddl/${ds}.sql")
    if size_limit_hit "${out}"; then
        echo "CREATE ${ds}: CedarDB CE size limit reached; stopping further loads" >&2
        SIZE_LIMIT_HIT=1; return 1
    fi
    if printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
        echo "CREATE ${ds} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE '(ERROR|FATAL):[^|]*' | head -1 | cut -c1-160)" >&2
        return 1
    fi
}

load_one_dataset() {
    local ds="$1" stmt out t0 rc ok=1 bytes table
    ensure_up || { echo "LOAD ${ds}: server unavailable" >&2; return 1; }   # revive after a prior crash
    t0=${SECONDS}
    echo "=== CREATE ${ds} tables ===" >&2
    run_ddl "${ds}" || return 1
    # Read the load script on FD 3, not stdin: PGload runs `docker run -i`, which would otherwise
    # consume the rest of the script (leaving only the first table loaded).
    while IFS= read -r stmt <&3; do
        case "${stmt}" in ''|--*) continue ;; esac
        echo "=== ${ds}: ${stmt} ===" >&2
        out=$(PGload "${stmt}"); rc=$?
        if size_limit_hit "${out}"; then
            echo "LOAD ${ds}: CedarDB CE size limit reached; stopping further loads" >&2
            ok=0; SIZE_LIMIT_HIT=1; break
        fi
        if [ "${rc}" -eq 124 ]; then
            echo "LOAD ${ds} TIMED OUT after ${LOAD_TIMEOUT}s -> benchmark skipped" >&2; ok=0
        elif printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
            echo "LOAD ${ds} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)" >&2; ok=0
        fi
    done 3< <(sed -e "s#{{DATA}}#${CDATA}#g" "${HERE}/load/${ds}.sql")
    # Statistics are timed SEPARATELY and reported as stats_time.
    STATS_SECS=0
    if [ "${ok}" = 1 ] && [ -n "${STATISTICS}" ]; then
        st0=${SECONDS}
        for table in ${TABLES[$ds]}; do
            echo "=== ANALYZE ${ds}.${table} ===" >&2
            out=$(PG "ANALYZE \"${ds}\".\"${table}\";")
            printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:' \
                && echo "statistics on ${ds}.${table} failed: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-140)" >&2
        done
        STATS_SECS=$((SECONDS - st0))
        printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
        echo "statistics on ${ds}: ${STATS_SECS}s" >&2
    fi
    if [ "${ok}" = 1 ]; then
        bytes=$(PG "SELECT COALESCE(SUM(pg_total_relation_size(c.oid)),0) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${ds}' AND c.relkind='r';" 2>/dev/null | tr -cd '0-9')
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" "${bytes:-0}" >> "${LOAD_STATS}"
        echo "loaded ${ds} in $((SECONDS - t0))s, ${bytes:-0} bytes" >&2
    fi
}

# True only if EVERY table of this benchmark exists and holds at least one row.
dataset_fully_loaded() {
    local ds="$1" table out cnt
    for table in ${TABLES[$ds]}; do
        # PG() merges stderr, so a missing table yields an error whose text can itself contain
        # digits -- extract only a line that is purely a number, and bail on any error.
        out=$(PG "SELECT count(*) FROM \"${ds}\".\"${table}\";")
        printf '%s' "${out}" | grep -qiE 'error|does not exist' && return 1
        cnt=$(printf '%s' "${out}" | grep -oxE '[0-9]+' | head -1)
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

# A results row of all-null, for a query that was never run.
null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times in ONE psql session (first cold -- fresh session plus dropped OS
# cache -- the rest hot). psql's \timing prints "Time: X.XXX ms" per statement; convert to
# seconds.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" i script out reals
    drop_caches
    script="SET search_path TO \"${ds}\";"$'\n'"SET statement_timeout=${QUERY_TIMEOUT}000;"$'\n'"\\timing on"$'\n'
    for i in $(seq 1 "${TRIES}"); do script+="${query};"$'\n'; done
    out=$(printf '%s' "${script}" | timeout -k 10 "$((QUERY_TIMEOUT * TRIES + 60))" docker run --rm -i --network host \
          -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" psql -h127.0.0.1 -p5432 -U postgres -d postgres 2>&1)
    # Match psql's error prefix ("ERROR:"/"FATAL:"), not "error" in result data.
    if printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
        echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE '(ERROR|FATAL):[^|]*' | head -1 | cut -c1-160)" >&2
        null_row; return
    fi
    mapfile -t reals < <(printf '%s' "${out}" | grep -oiE 'Time:[[:space:]]+[0-9.]+[[:space:]]*ms' | grep -oE '[0-9.]+')
    # No timings at all usually means the query crashed the server (connection dropped, which
    # doesn't print "ERROR:"). Revive it so the rest of the run isn't lost to a dead server.
    if [ "${#reals[@]}" -eq 0 ]; then
        echo "${label}: no timing (server may have crashed)" >&2
        ensure_up || true
    fi
    local res="[" v
    for i in $(seq 1 "${TRIES}"); do
        v="${reals[$((i-1))]:-}"
        if [ -n "${v}" ]; then v=$(awk -v x="${v}" 'BEGIN{printf "%.4f", x/1000}'); else v="null"; fi
        res+="${v}"; [ "${i}" -ne "${TRIES}" ] && res+=", "
    done
    echo "${res}]"
}

actual_version() { PG 'SELECT version()' 2>/dev/null | head -1; }

emit_load_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# {"benchmark": seconds, ...}: time spent COLLECTING STATISTICS, per benchmark.
emit_stats_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${STAT_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${STAT_STATS}" || printf '{}'
}
emit_data_size_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$3} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

run_benchmark() {
    local ACTUAL ds query FIRST=1 qnum=0 row ds_loaded FULLY_LOADED="" n
    ACTUAL="$(actual_version)"
    echo "benchmarking ${SYSTEM} ${VERSION} (reports ${ACTUAL:-unknown})" >&2
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
            case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
            n=0
            # Read queries on FD 3 (not stdin) so the per-query psql container cannot consume the
            # query file.
            while IFS= read -r query <&3; do
                [ -z "${query}" ] && continue
                query="${query%;}"
                qnum=$((qnum + 1)); n=$((n + 1))
                if [ "${ds_loaded}" = 0 ]; then
                    row="$(null_row)"
                    echo "q${qnum} [${ds}]: SKIPPED (not loaded); recording null" >&2
                else
                    row="$(run_query "${ds}" "${query}" "q${qnum} [${ds}]")"
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
    # Write to a temp file and rename -- the one deliberate deviation from the versions runner,
    # which writes in place: an interrupted run (Ctrl-C, a killed shell) leaves a half-written
    # results file that generate-results.sh cannot parse, so the run looks complete but is not.
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
}

# ---- run ----
announce_cache_mode
if [ -n "${QUERY_ONLY}" ]; then
    trap - EXIT                       # this run did not start it, so it must not tear it down
    PG 'SELECT 1' 2>/dev/null | grep -q '^1$' || {
        echo "QUERY_ONLY=1, but CedarDB is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "server left running (this run did not start it). Tear down with:" >&2
    echo "    docker rm -fv ${CONTAINER}" >&2
    exit 0
fi

trap stop_server EXIT
start_server || { echo "cannot start ${SYSTEM} ${VERSION}" >&2; exit 1; }
: > "${LOAD_STATS}"; : > "${STAT_STATS}"
for ds in ${LOAD_DATASETS}; do
    [ "${SIZE_LIMIT_HIT}" = 1 ] && { echo "=== ${ds}: skipped, CedarDB CE size limit already reached ===" >&2; continue; }
    load_one_dataset "${ds}" || true
done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "server left running on 127.0.0.1:5432. Connect with:" >&2
    echo "    PGPASSWORD=${PASSWORD} psql -h127.0.0.1 -p5432 -U postgres -d postgres" >&2
    echo "    (then: SET search_path TO <benchmark>;)" >&2
    echo "Tear down with: docker rm -fv ${CONTAINER}" >&2
    exit 0
fi
run_benchmark
