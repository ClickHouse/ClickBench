#!/usr/bin/env bash
# Benchmark StarRocks inside Docker: the official all-in-one image (FE + BE in one container),
# the prepared Parquet loaded with INSERT ... SELECT * FROM FILES(), every query timed from the
# server-side query profile, and results/starrocks.json in the shape every runner here writes.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # ANALYZE TABLE after loading (reported as stats_time)
#
# The schema and queries are explicit SQL files:
#
#   ddl/<benchmark>.sql       CREATE DATABASE + CREATE TABLE ... ORDER BY (key), hand-maintained
#   load/<benchmark>.sql      one INSERT ... FROM FILES() per table
#   queries/<benchmark>.sql   one query per line

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"    # on the host
# Where DATA is bind-mounted inside the container. NOT /data: the allin1 image keeps its own
# deployment there (/data/deploy), so a read-only mount over it makes the container fail to
# start at all ("mkdir /data/deploy: read-only file system").
CDATA_DIR="/benchdata"
# Where the allin1 image keeps the BE config.
BE_CONF="/data/deploy/starrocks/be/conf/be.conf"
# What {{DATA}} in load/*.sql expands to.
CDATA="file://${CDATA_DIR}"
TRIES="${TRIES:-6}"                                    # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
# The BE's own data caches. Default 0 disables them the way ClickBench's starrocks/install does
# (be.conf: disable_storage_page_cache, datacache_enable).
ENGINE_CACHES="${ENGINE_CACHES:-0}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
# Loads (INSERT ... FROM FILES) on the biggest tables can crawl; cap them server-side too.
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1200}"
# STATISTICS=1 runs one ANALYZE TABLE per loaded table (see load_one_dataset) so the optimiser
# has statistics.
STATISTICS="${STATISTICS:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there.
# benchmark's `phase load` did.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a server that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi

SYSTEM="StarRocks"
VERSION="4.1.4"
RELEASE_DATE="2026-08-06"   # release date of the pinned version, reported in the results
IMAGE="starrocks/allin1-ubuntu:${VERSION}"
CONTAINER="dbbench_starrocks"
USE_PROFILE=1               # 1: read server-side time from the query profile; 0: wall clock
BASE_OVERHEAD=0             # measured docker-exec+connect overhead to subtract in wall-clock mode
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
OUT="${ROOT}/results/starrocks/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/starrocks/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/starrocks.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/starrocks.statstimes.tsv"
SIZE_STATS="${ROOT}/logs/starrocks.sizes.tsv"
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

# --- StarRocks client (mysql lives inside the image; talk to the FE over 127.0.0.1:9030) ---
# </dev/null: `docker exec -i` would otherwise read the caller's stdin.
M()  { docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N "$@" </dev/null; }
Mq() { M -e "$1"; }                                                          # one statement

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
cleanup() { docker rm -fv "${CONTAINER}" >/dev/null 2>&1; }

# Start the container (mounting the data dir read-only) and wait for a live FE + BE.
start_server() {
    cleanup
    [ -d "${DATA}" ] || { echo "no data directory ${DATA}" >&2; return 1; }
    echo "starting ${SYSTEM} ${VERSION} from image ${IMAGE}" >&2
    docker pull "${IMAGE}" >/dev/null 2>&1
    # be.conf has to be written BEFORE the BE boots, so the image's own entrypoint is wrapped
    # rather than replaced: tini and ./entrypoint.sh are what the image would have run anyway
    # (WorkingDir is /data/deploy, hence the relative path).
    local pre=""
    if [ "${ENGINE_CACHES}" = 0 ]; then
        pre="printf '\ndisable_storage_page_cache = true\ndatacache_enable = false\n' >> ${BE_CONF}; "
    fi
    docker run -d --name "${CONTAINER}" -p 9030:9030 -p 8030:8030 -p 8040:8040 \
        -v "${DATA}:${CDATA_DIR}:ro" --entrypoint bash "${IMAGE}" \
        -c "${pre}exec /usr/bin/tini-static -- ./entrypoint.sh" >/dev/null || return 1
    # Wait for FE and BE.
    local waited=0
    until Mq 'SELECT 1' >/dev/null 2>&1; do
        sleep 5; waited=$((waited + 5))
        [ "${waited}" -gt 300 ] && { echo "FE did not come up in 300s; last container logs:" >&2
            docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true; return 1; }
    done
    waited=0
    until [ "$(Mq 'SHOW BACKENDS' 2>/dev/null | awk -F'\t' '{print $9}' | grep -c true)" -ge 1 ]; do
        sleep 5; waited=$((waited + 5))
        [ "${waited}" -gt 300 ] && { echo "BE did not register in 300s" >&2; return 1; }
    done
    # Result cache off, explicitly (already the default on 4.1.4).
    Mq "SET GLOBAL enable_query_cache = false;" >/dev/null 2>&1 || true
    # Read the values back from the BE rather than trusting the append.
    local varz
    varz=$(curl -s --max-time 10 http://127.0.0.1:8040/varz 2>/dev/null \
           | grep -E '^(disable_storage_page_cache|datacache_enable)=' | tr '\n' ' ')
    echo "StarRocks up ($(Mq 'SELECT current_version()' 2>/dev/null | head -1)); result cache off; BE: ${varz:-could not read /varz}" >&2
}

# Load one benchmark: create its database and tables from ddl/, then run load/ one statement at
# a time.
load_one_dataset() {
    local ds="$1" line table out rc t0 secs ok=1
    t0=${SECONDS}
    echo "=== CREATE ${ds} tables ===" >&2
    # Create database and select it with -D.
    Mq "CREATE DATABASE IF NOT EXISTS ${ds};" >/dev/null 2>&1
    out=$(docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N -D "${ds}" \
          < "${HERE}/ddl/${ds}.sql" 2>&1)
    if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
        echo "CREATE ${ds} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
        return 1
    fi
    # Read the load script on FD 3, not stdin.
    while IFS= read -r line <&3; do
        case "${line}" in ''|--*) continue ;; esac
        # Table name from the statement itself.
        table="${line##* INTO }"; table="${table%% *}"; table="${table#*.}"
        echo "=== LOAD ${ds}.${table} ===" >&2
        out=$(timeout -k 10 "$((LOAD_TIMEOUT + 60))" docker exec -i "${CONTAINER}" \
              mysql -h127.0.0.1 -P9030 -uroot -N --connect-timeout=30 \
              -e "SET query_timeout=${LOAD_TIMEOUT}; ${line}" </dev/null 2>&1); rc=$?
        if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
            echo "LOAD ${ds}.${table} TIMED OUT after ${LOAD_TIMEOUT}s -> ${ds} skipped" >&2; ok=0
        elif printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
            echo "LOAD ${ds}.${table} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)" >&2; ok=0
        fi
    done 3< <(sed -e "s#{{DATA}}#${CDATA}#g" "${HERE}/load/${ds}.sql")
    # ANALYZE
    # TABLE is a full collection and is synchronous here. A failure is logged and ignored.
    STATS_SECS=0
    if [ "${ok}" = 1 ] && [ -n "${STATISTICS}" ]; then
        st0=${SECONDS}
        for table in ${TABLES[$ds]}; do
            echo "=== ANALYZE ${ds}.${table} ===" >&2
            out=$(Mq "ANALYZE TABLE ${ds}.\`${table}\`;" 2>&1)
            printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \(' \
                && echo "statistics on ${ds}.${table} failed: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-140)" >&2
        done
        STATS_SECS=$((SECONDS - st0))
        printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
        echo "statistics on ${ds}: ${STATS_SECS}s" >&2
    fi
    if [ "${ok}" = 1 ]; then
        secs=$((SECONDS - t0 - STATS_SECS))
        printf '%s\t%s\n' "${ds}" "${secs}" >> "${LOAD_STATS}"
        echo "loaded ${ds} in ${secs}s" >&2
    fi
}

# On-disk data size of a database, in bytes, from SHOW DATA: its "Total" row is a human-readable
# size ("13.324 GB") -> bytes. information_schema.tables.DATA_LENGTH is no use here -- it stays 0
# until background compaction runs.
#
# SHOW DATA is not immediate: the size comes from the BEs' periodic tablet report, so right after
# a load the Total might reads "0.000 B".
sr_data_size() {
    local bytes
    bytes=$(sr_show_data "$1")
    [ -n "${bytes}" ] && printf '%s' "${bytes}" || printf '0'
}
sr_show_data() {
    local db="$1"
    Mq "USE ${db}; SHOW DATA;" 2>/dev/null | awk -F'\t' '
        $1=="Total" { n=split($2, a, " "); v=a[1]+0; u=(n>1?a[2]:"B");
            m=1; if(u=="KB")m=1024; else if(u=="MB")m=1024^2; else if(u=="GB")m=1024^3;
                 else if(u=="TB")m=1024^4; else if(u=="PB")m=1024^5;
            printf "%d", v*m; found=1; exit }
        END { if(!found) print 0 }'
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

# Parse a StarRocks profile "Time" cell (e.g. "14ms", "1s234ms", "2s", "1m2s") to seconds.
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

# Probe once for SHOW PROFILELIST; without it server-side profile timing is impossible and we
# fall back to wall clock, measuring the connect/exec baseline to subtract. The fall back should
# never fire.
detect_profile() {
    local probe
    probe=$(Mq "SHOW PROFILELIST LIMIT 1;" 2>&1)
    if grep -qiE 'ERROR [0-9]+ \(|syntax|not supported|unknown' <<<"${probe}"; then
        USE_PROFILE=0
        local j t0 t1 best=99
        for j in 1 2 3 4 5; do
            t0=$(date +%s.%N)
            Mq "SELECT 1;" >/dev/null 2>&1
            t1=$(date +%s.%N)
            best=$(awk -v a="${t0}" -v b="${t1}" -v m="${best}" 'BEGIN{d=b-a; print (d<m?d:m)}')
        done
        BASE_OVERHEAD="${best}"
        echo "${SYSTEM} ${VERSION}: no SHOW PROFILELIST -> wall-clock timing (baseline ${BASE_OVERHEAD}s)" >&2
    fi
}

# Run one query TRIES times, print a JSON array "[t1, ..., tN]". Two timing methods:
#  - profile: server-side execution time.
#  - wall clock (no profile): elapsed around the query minus the measured connect baseline.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" db i out qid t t0 t1 reals=()
    db="${ds}"   # ddl/<benchmark>.sql creates a database named after the benchmark
    for i in $(seq 1 "${TRIES}"); do
        [ "${i}" = 1 ] && drop_caches
        if [ "${USE_PROFILE}" = 1 ]; then
            out=$(timeout -k 10 "$((QUERY_TIMEOUT + 30))" docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N --connect-timeout=30 \
                  -e "SET enable_profile=true; SET query_timeout=${QUERY_TIMEOUT}; USE ${db}; ${query}; SELECT concat('__QID__:', last_query_id());" </dev/null 2>&1)
            if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
                echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
                reals=(); break
            fi
            qid=$(printf '%s' "${out}" | grep -oE '__QID__:[a-f0-9-]+' | head -1 | cut -d: -f2)
            # The profile is published asynchronously, so a heavy query's row can be absent from
            # SHOW PROFILELIST the instant it returns.
            t=""
            for _ in 1 2 3; do
                t=$(Mq "SHOW PROFILELIST LIMIT 100;" 2>/dev/null \
                      | awk -F'\t' -v id="${qid}" '$1==id{print $3; exit}')
                [ -n "${t}" ] && break
                sleep 1
            done
            if [ -n "${t}" ]; then
                reals+=("$(time_to_sec "${t}")")
            else
                echo "${label}: ran OK but its profile (${qid:-no query id}) never appeared in SHOW PROFILELIST; recording null" >&2
                reals+=("null")
            fi
        else
            t0=$(date +%s.%N)
            out=$(timeout -k 10 "$((QUERY_TIMEOUT + 30))" docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N --connect-timeout=30 -D "${db}" \
                  -e "SET query_timeout=${QUERY_TIMEOUT}; ${query};" </dev/null 2>&1)
            t1=$(date +%s.%N)
            if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
                echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
                reals=(); break
            fi
            reals+=("$(awk -v a="${t0}" -v b="${t1}" -v o="${BASE_OVERHEAD}" 'BEGIN{d=b-a-o; if(d<0)d=0; printf "%.3f", d}')")
        fi
    done
    if [ "${#reals[@]}" -eq 0 ]; then null_row; return; fi
    local res="["
    for i in $(seq 1 "${TRIES}"); do res+="${reals[$((i-1))]:-null}"; [ "${i}" -ne "${TRIES}" ] && res+=", "; done
    echo "${res}]"
}

actual_version() { Mq 'SELECT current_version()' 2>/dev/null | head -1; }

emit_load_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# {"benchmark": seconds, ...}: time spent COLLECTING STATISTICS, per benchmark, kept OUT of
# load_time.
emit_stats_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${STAT_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${STAT_STATS}" || printf '{}'
}
# Sizes are collected after the queries, into their own file (benchmark, bytes).
emit_data_size_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${SIZE_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${SIZE_STATS}" || printf '{}'
}

# Time every query and write results/starrocks.json.
run_benchmark() {
    local ACTUAL ds query FIRST=1 qnum=0 row ds_loaded FULLY_LOADED="" n
    ACTUAL="$(actual_version)"
    echo "benchmarking ${SYSTEM} ${VERSION} (reports ${ACTUAL:-unknown})" >&2
    for ds in ${QUERY_ORDER}; do
        if dataset_fully_loaded "${ds}"; then FULLY_LOADED+=" ${ds}";
        else echo "=== ${ds}: not fully loaded; skipping its queries, load time and size ===" >&2; fi
    done
    # Run every query first, buffering the rows, so the sizing below happens AFTER the query
    # phase rather than blocking in front of it.
    local ROWS; ROWS="$(mktemp)"
    for ds in ${QUERY_ORDER}; do
        case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
        n=0
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
            printf '%s\n' "${row}" >> "${ROWS}"
        done 3< "${HERE}/queries/${ds}.sql"
        # Keep result[] at its fixed length even if a query file is short.
        while [ "${n}" -lt "${QUERY_COUNT[$ds]}" ]; do
            printf '%s\n' "$(null_row)" >> "${ROWS}"
            n=$((n + 1))
        done
    done

    # Now try to get the sizes.
    for ds in ${FULLY_LOADED}; do
        printf '%s\t%s\n' "${ds}" "$(sr_data_size "${ds}")" >> "${SIZE_STATS}"
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
        while IFS= read -r row; do
            [ "${FIRST}" = 0 ] && echo ','
            FIRST=0
            printf '        %s' "${row}"
        done < "${ROWS}"
        echo
        echo '    ]'
        echo '}'
    # Write to a temp file and rename: an interrupted run (Ctrl-C, a killed shell) would
    # otherwise leave a half-written results file behind, and generate-results.sh then fails to
    # parse it -- the run looks complete but the JSON is truncated mid-array.
    } > "${OUT}.tmp"
    mv "${OUT}.tmp" "${OUT}"
    rm -f "${ROWS}"
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
        echo "QUERY_ONLY=1, but StarRocks is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    detect_profile
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

trap cleanup EXIT
start_server || { echo "cannot start ${SYSTEM} ${VERSION}" >&2; exit 1; }
detect_profile
: > "${LOAD_STATS}"; : > "${STAT_STATS}"; : > "${SIZE_STATS}"
for ds in ${LOAD_DATASETS}; do load_one_dataset "${ds}" || true; done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "server left running. Connect with:" >&2
    echo "    docker exec -it ${CONTAINER} mysql -h127.0.0.1 -P9030 -uroot -D <benchmark>" >&2
    echo "Tear down with: docker rm -fv ${CONTAINER}" >&2
    exit 0
fi
run_benchmark
