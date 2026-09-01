#!/usr/bin/env bash
# Benchmark Apache Doris inside Docker.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # ANALYZE TABLE ... WITH SYNC after loading (-> stats_time)
#
# The schema and queries now come from explicit SQL files:
#
#   ddl/<benchmark>.sql       CREATE DATABASE + CREATE TABLE ... DUPLICATE KEY(...), hand-maintained
#   load/<benchmark>.sql      one INSERT per table via local()
#   queries/<benchmark>.sql   one query per line
#
# Two Doris specifics those files carry, which this runner has to serve:
#   * DUPLICATE KEY columns must be an ordered PREFIX of the table ("Key columns should be a
#     ordered prefix") and ORDER BY is rejected on a duplicate-key table, so ddl/ declares the
#     spec key columns FIRST -- a different column order from the generator's Parquet -- and
#     load/ names every column in GENERATOR order so the positional `SELECT *` still lands in the
#     right column.
#   * local() is BACKEND-scoped: it takes a backend id and a path relative to the BE's
#     user_files_secure dir, not a URI the way StarRocks' FILES() does. So the host data
#     directory is bind-mounted into the BE at ${BE_HOME}/user_files_secure, and the load files'
#     {{DATA}} and {{BEID}} placeholders are substituted with that relative prefix and with the
#     id read from SHOW BACKENDS at startup.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"
TRIES="${TRIES:-6}"                                    # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
# The BE's own data caches. Default 0 disables them the way ClickBench's doris/install does
# (be.conf: disable_storage_page_cache, segment_cache_capacity).
ENGINE_CACHES="${ENGINE_CACHES:-0}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1200}"
# STATISTICS=1 runs one `ANALYZE TABLE <db>.<table> WITH SYNC` per loaded table (see
# load_one_dataset), so the optimiser has statistics.
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

SYSTEM="Doris"
VERSION="4.1.3"
RELEASE_DATE="2026-07-08"   # release date of the pinned version, reported in the results
FE_IMAGE="apache/doris:fe-${VERSION}"
BE_IMAGE="apache/doris:be-${VERSION}"
# Where the BE image keeps its config.
BE_CONF="/opt/apache-doris/be/conf/be.conf"
FE_CONTAINER="dbbench_doris_fe"
BE_CONTAINER="dbbench_doris_be"
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
OUT="${ROOT}/results/doris/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/doris/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/doris.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/doris.statstimes.tsv"
mkdir -p "${ROOT}/logs" "$(dirname "${OUT}")"

BE_HOME=/opt/apache-doris/be
# Where the BE looks for local() inputs: file_path is resolved relative to this directory, so
# ${DATA} is mounted there and {{DATA}} in the load files becomes this bare relative prefix
# (i.e. user_files_secure/parquet/<benchmark>/<table>.parquet).
BE_DATA="user_files_secure"
BEID=""                     # backend id, needed by local(); set by start_server
USE_PROFILE=1               # 1: server-side time from the FE profile endpoint; 0: client-side
FE_HTTP=8030                # FE HTTP port, where the query profile is served

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

# --- Doris client (mysql lives inside the FE image; talk to the FE over 127.0.0.1:9030) ---
# MYSQL_TIMEOUT (seconds), when set, wraps the client in `timeout -k 10`.
MYSQL_TIMEOUT=""
M() {
    ${MYSQL_TIMEOUT:+timeout -k 10 ${MYSQL_TIMEOUT}} docker exec -i "${FE_CONTAINER}" \
        mysql -h127.0.0.1 -P9030 -uroot -N --connect-timeout=30 "$@"
}
Mq() { M -e "$1" </dev/null; }
show_backends() {
    docker exec -i "${FE_CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot \
        -e 'SHOW BACKENDS\G' </dev/null 2>/dev/null
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
fmt_err() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-160; }

# Start FE, wait for it, then start BE and wait for it to register Alive.
start_server() {
    stop_server
    # Doris issues a large number of small mmaps; the default limit is easy to exceed.
    sudo sysctl -wq vm.max_map_count=2000000 2>/dev/null || true
    echo "starting Doris ${VERSION} FE (${FE_IMAGE})" >&2
    docker pull "${FE_IMAGE}" >/dev/null 2>&1
    docker pull "${BE_IMAGE}" >/dev/null 2>&1
    docker run -d --name "${FE_CONTAINER}" --network host \
        -e FE_SERVERS="fe1:127.0.0.1:9010" -e FE_ID=1 "${FE_IMAGE}" >/dev/null || return 1
    # Readiness is SHOW FRONTENDS, NOT `SELECT 1`: in Doris 4.x even `SELECT 1` is planned with a
    # scan node, so it fails with "No backend available as scan node" until a BE registers -- and
    # the BE is only started below, once the FE answers. Probing with SELECT 1 deadlocks the two
    # waits against each other. SHOW FRONTENDS reads FE metadata only and answers ~20s in.
    # 600s, not 300: the FE builds its metadata on first boot, which on a loaded host takes well
    # past five minutes. On failure dump the container's own log -- otherwise the only symptom is
    # a timeout, which hides the real cause (a port clash, say).
    local waited=0
    until Mq 'SHOW FRONTENDS' >/dev/null 2>&1; do
        sleep 5; waited=$((waited + 5))
        if [ "${waited}" -gt 600 ]; then
            echo "FE did not come up in 600s; last log lines:" >&2
            docker logs --tail 20 "${FE_CONTAINER}" >&2 2>&1 || true
            return 1
        fi
    done
    echo "starting Doris ${VERSION} BE (${BE_IMAGE})" >&2
    # be.conf has to be written BEFORE the BE boots, so the image's own entrypoint is wrapped
    # rather than replaced: `bash entry_point.sh` is what the image would have run anyway
    # (WorkingDir is /opt/apache-doris, hence the relative path).
    local pre=""
    if [ "${ENGINE_CACHES}" = 0 ]; then
        pre="printf '\ndisable_storage_page_cache = true\nsegment_cache_capacity = 0\n' >> ${BE_CONF}; "
    fi
    docker run -d --name "${BE_CONTAINER}" --network host \
        -e FE_SERVERS="fe1:127.0.0.1:9010" -e BE_ADDR="127.0.0.1:9050" \
        -v "${DATA}:${BE_HOME}/${BE_DATA}:ro" --entrypoint bash "${BE_IMAGE}" \
        -c "${pre}exec bash entry_point.sh" >/dev/null || return 1
    waited=0
    until show_backends | grep -qE '^ *Alive: true'; do
        sleep 5; waited=$((waited + 5))
        if [ "${waited}" -gt 600 ]; then
            echo "BE did not register in 600s; last log lines:" >&2
            docker logs --tail 20 "${BE_CONTAINER}" >&2 2>&1 || true
            return 1
        fi
    done
    # The load statements need the backend id: local() is backend-scoped.
    BEID=$(show_backends | awk '/BackendId:/{print $2; exit}')
    [ -n "${BEID}" ] || { echo "could not read BackendId" >&2; return 1; }
    # The FE's SQL RESULT cache, off globally.
    Mq "SET GLOBAL enable_sql_cache = false;" >/dev/null 2>&1
    # Read the values back from the BE rather than trusting the append.
    local varz
    varz=$(curl -s --max-time 10 http://127.0.0.1:8040/varz 2>/dev/null \
           | grep -E '^(disable_storage_page_cache|segment_cache_capacity)=' | tr '\n' ' ')
    echo "FE result cache off (enable_sql_cache=false); BE: ${varz:-could not read /varz}" >&2
    echo "Doris up ($(actual_version), backend ${BEID})" >&2
}
stop_server() { docker rm -fv "${FE_CONTAINER}" "${BE_CONTAINER}" >/dev/null 2>&1; }

actual_version() { Mq 'SELECT @@version_comment' 2>/dev/null | head -1; }

# Parse a Doris profile "Total" cell (e.g. "14ms", "1s234ms", "2s", "1m2s") to seconds.
time_to_sec() {
    awk -v t="$1" 'BEGIN{
        s=0; n=""
        for(i=1;i<=length(t);i++){c=substr(t,i,1)
            if(c ~ /[0-9.]/){n=n c}
            else{ if(c=="m" && substr(t,i+1,1)=="s"){s+=n/1000; i++}
                  else if(c=="s"){s+=n}
                  else if(c=="m"){s+=n*60}
                  else if(c=="h"){s+=n*3600}
                  n="" }
        }
        printf "%.3f", s
    }'
}

# Fetch a query's server-side execution time from the FE's HTTP profile endpoint:
#
#     Summary:
#        - Profile ID: fcb7ae2753e14fe2-90b409080f8409a5
#        - Total: 282ms
profile_total() {
    curl -s -u root: --max-time 20 "http://127.0.0.1:${FE_HTTP}/api/profile?query_id=$1" 2>/dev/null \
        | grep -oE '\- Total: [0-9hmsun.]+' | head -1 | awk '{print $3}'
}

# Doris 4.x does NOT implement SHOW QUERY PROFILE.
detect_profile() {
    local qid probe
    qid=$(Mq "SET enable_profile=true; SELECT 1; SELECT concat('__QID__:', last_query_id());" 2>&1 \
          | grep -oE '__QID__:[a-f0-9-]+' | head -1 | cut -d: -f2)
    probe=""
    [ -n "${qid}" ] && probe="$(profile_total "${qid}")"
    if [ -z "${probe}" ]; then
        USE_PROFILE=0
        echo "FE profile endpoint unavailable -> client-side statement timing (mysql -vvv)" >&2
    else
        echo "server-side timing via the FE profile endpoint (probe read ${probe})" >&2
    fi
}

# Load one benchmark: create its database and tables from ddl/, then run load/ one statement per
# line. A USE precedes each statement (see below), so table names are unqualified. A table that fails leaves the
# whole benchmark unloaded (ok=0): no load time, no size, and its queries report null.
load_one_dataset() {
    local ds="$1" line table rel out t0 rc ok=1
    echo "=== CREATE ${ds} tables ===" >&2
    t0=${SECONDS}
    MYSQL_TIMEOUT="$((LOAD_TIMEOUT + 60))"
    out=$(M < "${HERE}/ddl/${ds}.sql" 2>&1); rc=$?
    if [ "${rc}" -ne 0 ] || printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
        MYSQL_TIMEOUT=""
        echo "CREATE ${ds} FAILED: $(fmt_err "${out}")" >&2; return 1
    fi
    # Read the load script on FD 3, not stdin: the `docker exec -i` calls below would otherwise
    # consume the script itself (after the first table).
    while IFS= read -r line <&3; do
        case "${line}" in ''|--*) continue ;; esac
        # Table name from the statement itself.
        table="${line##* INTO }"; table="${table%% *}"; table="${table#*.}"
        # A missing input is reported as a SKIP.
        rel="${line#*file_path\'=\'}"; rel="${rel%%\'*}"
        if [ "${rel}" != "${line}" ] && [ ! -f "${DATA}/${rel#"${BE_DATA}"/}" ]; then
            echo "SKIP ${ds}.${table}: ${rel#"${BE_DATA}"/} not present" >&2; ok=0; continue
        fi
        echo "=== ${line%% *} ${ds}.${table} ===" >&2
        # USE before the statement.
        out=$(Mq "SET query_timeout=${LOAD_TIMEOUT}; USE ${ds}; ${line}" 2>&1); rc=$?
        if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
            echo "LOAD ${ds}.${table} TIMED OUT after ${LOAD_TIMEOUT}s -> benchmark skipped" >&2; ok=0
        elif printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
            echo "LOAD ${ds}.${table} FAILED: $(fmt_err "${out}")" >&2; ok=0
        fi
    done 3< <(sed -e "s#{{DATA}}#${BE_DATA}#g" -e "s#{{BEID}}#${BEID}#g" "${HERE}/load/${ds}.sql")
    # WITH SYNC makes the collection synchronous, so the table is ready when this returns.
    STATS_SECS=0
    if [ "${ok}" = 1 ] && [ -n "${STATISTICS}" ]; then
        st0=${SECONDS}
        for table in ${TABLES[$ds]}; do
            echo "=== ANALYZE ${ds}.${table} ===" >&2
            out=$(Mq "ANALYZE TABLE ${ds}.\`${table}\` WITH SYNC;" 2>&1)
            printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \(' \
                && echo "statistics on ${ds}.${table} failed: $(fmt_err "${out}")" >&2
        done
        STATS_SECS=$((SECONDS - st0))
        printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
        echo "statistics on ${ds}: ${STATS_SECS}s" >&2
    fi
    MYSQL_TIMEOUT=""
    if [ "${ok}" = 1 ]; then
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" "$(be_data_size)" >> "${LOAD_STATS}"
        echo "loaded ${ds} in $((SECONDS - t0))s" >&2
    fi
}

# On-disk size of the BE's storage dir.
be_data_size() {
    docker exec -i "${BE_CONTAINER}" du -bs "${BE_HOME}/storage" </dev/null 2>/dev/null | awk '{print $1+0; exit}'
}

# True only if EVERY table of the benchmark exists and holds at least one row.
dataset_fully_loaded() {
    local ds="$1" table cnt out
    for table in ${TABLES[$ds]}; do
        # Check for an error BEFORE parsing a count.
        out=$(Mq "SELECT count(*) FROM ${ds}.\`${table}\`;" 2>&1)
        printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \(' && return 1
        cnt=$(printf '%s' "${out}" | grep -oxE '[0-9]+' | head -1)
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

# A results row of all-null, for a query that was never run.
null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times. Two timing methods:
#  - profile: server-side execution time. The query id comes from last_query_id() in the same
#    batch, then the profile is fetched from the FE over HTTP and matched on that id.
#  - client-side: the mysql client's own per-statement time, if the profile is unavailable.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" i out qid t t0 t1 reals=()
    for i in $(seq 1 "${TRIES}"); do
        [ "${i}" = 1 ] && drop_caches
        MYSQL_TIMEOUT="$((QUERY_TIMEOUT + 30))"
        if [ "${USE_PROFILE}" = 1 ]; then
            out=$(Mq "SET enable_profile=true; SET query_timeout=${QUERY_TIMEOUT}; USE ${ds}; ${query}; SELECT concat('__QID__:', last_query_id());" 2>&1)
            MYSQL_TIMEOUT=""
            if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
                echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
                reals=(); break
            fi
            qid=$(printf '%s' "${out}" | grep -oE '__QID__:[a-f0-9-]+' | head -1 | cut -d: -f2)
            # Same async-publish caveat as StarRocks: retry briefly, and log if it never shows,
            # rather than recording a bare null that looks like a failure.
            t=""
            for _ in 1 2 3; do
                t=$(profile_total "${qid}")
                [ -n "${t}" ] && break
                sleep 1
            done
            if [ -n "${t}" ]; then
                reals+=("$(time_to_sec "${t}")")
            else
                echo "${label}: ran OK but its profile (${qid:-no query id}) was not served by the FE; recording null" >&2
                reals+=("null")
            fi
        else
            # -vvv makes the client print its own per-statement time ("1 row in set (0.38 sec)"),
            # measured around the statement rather than around the whole docker-exec + connect.
            out=$(${MYSQL_TIMEOUT:+timeout -k 10 ${MYSQL_TIMEOUT}} docker exec -i "${FE_CONTAINER}" \
                  mysql -h127.0.0.1 -P9030 -uroot -vvv --connect-timeout=30 -D "${ds}" \
                  -e "SET query_timeout=${QUERY_TIMEOUT}; ${query};" </dev/null 2>&1)
            MYSQL_TIMEOUT=""
            if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
                echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
                reals=(); break
            fi
            t=$(printf '%s' "${out}" | grep -oE '\([0-9.]+ sec\)' | tail -1 | tr -cd '0-9.')
            if [ -n "${t}" ]; then
                reals+=("${t}")
            else
                echo "${label}: ran OK but the client printed no timing; recording null" >&2
                reals+=("null")
            fi
        fi
    done
    if [ "${#reals[@]}" -eq 0 ]; then null_row; return; fi
    local res="["
    for i in $(seq 1 "${TRIES}"); do res+="${reals[$((i-1))]:-null}"; [ "${i}" -ne "${TRIES}" ] && res+=", "; done
    echo "${res}]"
}

emit_load_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# {"benchmark": seconds, ...}: time spent COLLECTING STATISTICS, per benchmark, kept OUT of
# load_time. Before this existed the two were summed into load_time, so a STATISTICS=1 run could
# not be compared against a run without it -- at TPC-H SF100 statistics on lineitem alone is ~570s
# against a ~1200s load, so it dominated the difference. Empty when STATISTICS was not set, and
# always empty for a system with no statistics statement.
emit_stats_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${STAT_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${STAT_STATS}" || printf '{}'
}
# be_data_size() is a running total of the whole BE storage dir, so a benchmark's own size is the
# increase over the previous line. The first line's delta is measured from zero.
emit_data_size_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" '
        { d=$3-prev; prev=$3; if (index(L," "$1" ")>0 && d>0) s[$1]+=d }
        END{printf "{"; for(x in s)printf "%s\"%s\": %s",(n++?", ":""),x,s[x]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# Time every query and write results/doris.json.
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
            # Read queries on FD 3 (not stdin) so the per-query `docker exec -i` client calls
            # cannot consume the query file.
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
    Mq 'SELECT 1' 2>/dev/null | grep -q '^1$' || {
        echo "QUERY_ONLY=1, but the Doris FE is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    detect_profile
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "FE+BE left running (this run did not start them). Tear down with:" >&2
    echo "    docker rm -fv ${FE_CONTAINER} ${BE_CONTAINER}" >&2
    exit 0
fi

trap stop_server EXIT
start_server || { echo "cannot start Doris ${VERSION}" >&2; exit 1; }
detect_profile
: > "${LOAD_STATS}"; : > "${STAT_STATS}"
for ds in ${LOAD_DATASETS}; do load_one_dataset "${ds}" || true; done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "FE+BE left running. Connect with:" >&2
    echo "    docker exec -it ${FE_CONTAINER} mysql -h127.0.0.1 -P9030 -uroot -D <benchmark>" >&2
    echo "Tear down with: docker rm -fv ${FE_CONTAINER} ${BE_CONTAINER}" >&2
    exit 0
fi
run_benchmark
