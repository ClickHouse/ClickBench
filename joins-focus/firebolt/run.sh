#!/usr/bin/env bash
# Benchmark Firebolt Core inside Docker. Firebolt Core is the self-hosted build (a public
# image, no cloud account) driven over HTTP+SQL on port 3473 -- there is no client binary and no
# wire protocol to speak: every statement is a curl POST and the server answers with JSON.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # per-column ADD STATISTICS after loading (-> stats_time)
#
# Schema, load and queries are explicit files:
#
#   ddl/<benchmark>.sql       CREATE DATABASE + CREATE TABLE ... PRIMARY INDEX <key>
#   load/<benchmark>.sql      per table: CREATE EXTERNAL TABLE (full column list) + INSERT SELECT
#   queries/<benchmark>.sql   one query per line

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"                           # host side of the data mount
CDATA=/firebolt-core/data                              # where DATA is mounted in the container
TRIES="${TRIES:-6}"                                    # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
# Firebolt's scan cache is a DATA cache -- the counterpart of the StarRocks and Doris BE caches --
# so it follows the same switch, and all three engines are configured alike. The result and
# sub-result caches are off either way.
ENGINE_CACHES="${ENGINE_CACHES:-0}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1200}"
# See the header: statistics are per-column ALTERs from stats/<benchmark>.sql, timed separately.
STATISTICS="${STATISTICS:-}"

SYSTEM="Firebolt"
VERSION="4.31.13"
RELEASE_DATE="2026-04-24"   # release date of the pinned version, reported in the results
IMAGE="ghcr.io/firebolt-db/firebolt-core:4.31.13-0.20260424104720.5698ca5339fc"
CONTAINER="dbbench_firebolt"
PORT=3473
VOLUME="${HERE}/.fb/volume"                            # engine data dir
# KEEP_DATA=1 leaves the loaded data on disk when the run ends, for poking at it afterwards.
KEEP_DATA="${KEEP_DATA:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a engine that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi
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
OUT="${ROOT}/results/firebolt/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/firebolt/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/firebolt.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/firebolt.statstimes.tsv"
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

# --- HTTP client -------------------------------------------------------------------------
# Q <sql> [extra-params] -> response body. Caches are disabled per request so a cold run is
# actually cold; JSON_Compact is the format the published Firebolt benchmark uses.
# MAXTIME bounds one HTTP call.
NOCACHE='enable_result_cache=false&enable_subresult_cache=false'
if [ "${ENGINE_CACHES}" = 0 ]; then
    NOCACHE="${NOCACHE}&enable_scan_cache=false"
fi
MAXTIME=""
Q() {
    local sql="$1" params="${2:-}"
    curl -sS --max-time "${MAXTIME:-$((QUERY_TIMEOUT + 30))}" \
        "http://127.0.0.1:${PORT}/?${NOCACHE}&output_format=JSON_Compact${params:+&${params}}" \
        --data-binary "${sql}" 2>&1
}
# Each benchmark's database is named after the benchmark.
Qdb() { Q "$1" "database=$2"; }
# Firebolt answers 200 even for failures, so errors are detected in the body, not the status.
fb_failed() { printf '%s' "$1" | grep -q '"errors"'; }
# Extract the error text by parsing the JSON.
fb_error() {
    printf '%s' "$1" | python3 -c "
import json,sys
try:
    e=(json.load(sys.stdin).get('errors') or [{}])[0]
    print(' '.join((e.get('description') or str(e)).split())[:220])
except Exception:
    print(' '.join(sys.stdin.read().split())[:220])" 2>/dev/null
}
# First words of a statement, on one line, for a log message.
stmt_label() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | sed -e 's/^ //' | cut -c1-70; }

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

# Remove the container AND its data volume.
cleanup() {
    docker rm -fv "${CONTAINER}" >/dev/null 2>&1
    if [ -n "${KEEP_DATA}" ]; then
        echo "KEEP_DATA=1: leaving ${VOLUME} in place" >&2
    else
        rm -rf "${VOLUME}" 2>/dev/null || sudo rm -rf "${VOLUME}" 2>/dev/null || true
    fi
}

start_server() {
    cleanup
    mkdir -p "${VOLUME}"
    # uid/gid 1111: the engine self-checks and aborts if its dirs are not writable by it.
    sudo chown 1111:1111 "${VOLUME}" 2>/dev/null || true
    echo "starting ${SYSTEM} ${VERSION} (${IMAGE})" >&2
    docker pull "${IMAGE}" >/dev/null 2>&1
    docker run -dit --name "${CONTAINER}" --network host \
        --ulimit memlock=8589934592:8589934592 \
        --security-opt seccomp=unconfined \
        -v "${VOLUME}:/firebolt-core/volume" \
        -v "${DATA}:${CDATA}:ro" \
        "${IMAGE}" >/dev/null || return 1
    # Sentinel readiness, a status-code or substring check passes too early.
    local waited=0 MAXTIME=15
    until Q "SELECT 'fb-ready'" | grep -q 'fb-ready'; do
        sleep 5; waited=$((waited + 5))
        if [ "${waited}" -gt 600 ]; then
            echo "Firebolt did not become healthy in 600s; last log lines:" >&2
            docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true
            return 1
        fi
    done
    echo "Firebolt up ($(actual_version))" >&2
}

actual_version() {
    Q 'SELECT version()' | tr -d '\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^"]*' | head -1
}

run_script() {
    local ds="$1" file="$2" stmt out table hrc rc=0
    while IFS= read -r -d ';' stmt <&3; do
        case "${stmt}" in *[![:space:]]*) : ;; *) continue ;; esac
        if [[ "${stmt}" =~ ^[[:space:]]*(CREATE|DROP)[[:space:]]+DATABASE ]]; then
            out=$(Q "${stmt}"); hrc=$?
        else
            out=$(Qdb "${stmt}" "${ds}"); hrc=$?
        fi
        # Two failure modes: the HTTP call itself failed (curl hit --max-time, connection went
        # away), which leaves an EMPTY body and so would slip past the "errors" check; or the
        # call returned 200 with an error object in the body, which is how Firebolt reports
        # every SQL error.
        if [ "${hrc}" != 0 ]; then
            echo "${ds}: '$(stmt_label "${stmt}")' FAILED (http rc=${hrc}, exceeded ${MAXTIME:-$((QUERY_TIMEOUT + 30))}s?)" >&2
        elif fb_failed "${out}"; then
            echo "${ds}: '$(stmt_label "${stmt}")' FAILED: $(fb_error "${out}")" >&2
        else
            continue
        fi
        rc=1
        # Drop failed partial inserts.
        if [[ "${stmt}" =~ ^[[:space:]]*INSERT[[:space:]]+INTO[[:space:]]+\"([^\"]+)\" ]]; then
            table="${BASH_REMATCH[1]}"
            echo "${ds}: dropping the incomplete table ${table}" >&2
            Qdb "DROP TABLE IF EXISTS \"${table}\"" "${ds}" >/dev/null
        fi
    done 3< <(sed -e "s#{{DATA}}#${CDATA}#g" -e '/^[[:space:]]*--/d' "${file}")
    return "${rc}"
}

# Engine data dir size. Cumulative across benchmarks (one engine, one volume).
volume_size() { sudo du -bs "${VOLUME}" 2>/dev/null | awk '{print $1+0; exit}'; }

load_one_dataset() {
    local ds="$1" t0 rc=0 st0
    MAXTIME="${LOAD_TIMEOUT}"
    echo "=== CREATE ${ds} tables ===" >&2
    if ! run_script "${ds}" "${HERE}/ddl/${ds}.sql"; then
        echo "CREATE ${ds} FAILED" >&2; MAXTIME=""; return 1
    fi
    echo "=== LOAD ${ds} ===" >&2
    t0=${SECONDS}
    run_script "${ds}" "${HERE}/load/${ds}.sql" || rc=1
    # Statistics are timed SEPARATELY into STAT_STATS and subtracted from load_time below.
    STATS_SECS=0
    if [ -n "${STATISTICS}" ] && [ -f "${HERE}/stats/${ds}.sql" ]; then
        echo "=== ADD STATISTICS ${ds} ($(grep -c '^ALTER' "${HERE}/stats/${ds}.sql") statements) ===" >&2
        st0=${SECONDS}
        run_script "${ds}" "${HERE}/stats/${ds}.sql" \
            || echo "statistics on ${ds}: some statements failed; continuing" >&2
        STATS_SECS=$((SECONDS - st0))
        printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
        echo "statistics on ${ds}: ${STATS_SECS}s" >&2
    fi
    MAXTIME=""
    printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" "$(volume_size)" >> "${LOAD_STATS}"
    if [ "${rc}" = 0 ]; then
        echo "loaded ${ds} in $((SECONDS - t0))s" >&2
    else
        echo "LOAD ${ds} had failures; it will not be benchmarked" >&2
    fi
    return "${rc}"
}

# True only if EVERY table of the benchmark exists and holds at least one row.
dataset_fully_loaded() {
    local ds="$1" table out n
    for table in ${TABLES[$ds]}; do
        out=$(Qdb "SELECT count(*) FROM \"${table}\"" "${ds}")
        fb_failed "${out}" && return 1
        # Parse the JSON rather than grep it: Firebolt pretty-prints.
        n=$(printf '%s' "${out}" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin).get('data') or []
    print(d[0][0] if d and d[0] else 0)
except Exception: print(0)" 2>/dev/null)
        [ -n "${n}" ] && [ "${n}" != "0" ] || return 1
    done
    return 0
}

# A results row of all-null, for a query that was never run.
null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times against the benchmark's database.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" i out rc t reals=()
    for i in $(seq 1 "${TRIES}"); do
        [ "${i}" = 1 ] && drop_caches
        out=$(Qdb "${query}" "${ds}"); rc=$?
        if [ "${rc}" != 0 ]; then
            echo "${label}: FAILED (http rc=${rc}, timeout >$((QUERY_TIMEOUT + 30))s?): $(stmt_label "${out}")" >&2
            reals=(); break
        fi
        if fb_failed "${out}"; then
            echo "${label}: FAILED: $(fb_error "${out}")" >&2
            reals=(); break
        fi
        t=$(printf '%s' "${out}" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('statistics',{}).get('elapsed',''))
except Exception: print('')" 2>/dev/null)
        if [ -n "${t}" ]; then
            reals+=("$(awk -v x="${t}" 'BEGIN{printf "%.3f", x}')")
        else
            echo "${label}: ran OK but the response carried no statistics.elapsed; recording null" >&2
            reals+=("null")
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
# load_time.
emit_stats_time_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${STAT_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${STAT_STATS}" || printf '{}'
}
emit_data_size_json() {  # $1 = fully-loaded benchmarks; volume size is cumulative, so difference
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" '
        { d=$3-prev; prev=$3; if (index(L," "$1" ")>0 && d>0) s[$1]+=d }
        END{printf "{"; for(x in s)printf "%s\"%s\": %s",(n++?", ":""),x,s[x]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# Time every query and write results/firebolt.json.
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
    # The SENTINEL check, exactly as start_server uses it.
    ( MAXTIME=15; Q "SELECT 'fb-ready'" ) 2>/dev/null | grep -q 'fb-ready' || {
        echo "QUERY_ONLY=1, but Firebolt Core is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "engine left running (this run did not start it). Tear down with:" >&2
    echo "    docker rm -fv ${CONTAINER} && sudo rm -rf ${VOLUME}" >&2
    exit 0
fi

trap cleanup EXIT
start_server || { echo "cannot start ${SYSTEM} ${VERSION}" >&2; exit 1; }
[ -n "${STATISTICS}" ] && echo "STATISTICS=1: per-column ALTER ... ADD STATISTICS after each load (see stats/)" >&2
: > "${LOAD_STATS}"; : > "${STAT_STATS}"
for ds in ${LOAD_DATASETS}; do load_one_dataset "${ds}" || true; done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "engine left running on 127.0.0.1:${PORT}. Query with:" >&2
    echo "    curl -s \"http://127.0.0.1:${PORT}/?database=<benchmark>\" --data-binary \"SELECT 1\"" >&2
    echo "Tear down with: docker rm -fv ${CONTAINER} && sudo rm -rf ${VOLUME}" >&2
    exit 0
fi
run_benchmark
