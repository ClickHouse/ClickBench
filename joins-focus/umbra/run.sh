#!/usr/bin/env bash
# Benchmark Umbra inside Docker. Umbra speaks the PostgreSQL wire protocol, so every statement
# goes through psql running in a throwaway postgres client container over the host network --
# the host itself needs no psql.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # ANALYZE after loading (reported as stats_time)
#
# Reduced from versions/umbra/run-version.sh. Everything about HOW it runs is unchanged: the
# same container flags and host sysctls, the same psql-over-host-network client, the same
# \timing measurement with all TRIES in ONE psql session, the same du(1) sizing, and the same
# results JSON. What is gone is the version dimension -- one pinned image, so no versions.tsv
# lookup, no version argument, no load/bench PHASE split, no release_date -- along with the CSV
# generation step (the data is pre-generated) and the DDL derivation from the prepared Native
# schema (the old pg_ddl / pg_key pair). Schema, load and queries now come from explicit SQL
# files:
#
#   ddl/<benchmark>.sql       CREATE SCHEMA IF NOT EXISTS + DROP TABLE IF EXISTS + CREATE TABLE
#   load/<benchmark>.sql      one COPY per table
#   queries/<benchmark>.sql   one query per line
#
# Each benchmark loads into its own schema because TPC-H and TPC-DS both define a `customer`
# table. Umbra facts, each of which cost a debug cycle in the versions benchmark:
#   * NO Parquet reader at all. Both `FROM '<file>.parquet'` and read_parquet() are rejected
#     ("unknown function or overload read_parquet(text)"), so CSV + COPY is the only load path
#     and there is no detect/fallback to do -- it is always CSV.
#   * COPY reads the file on the SERVER side, i.e. inside the container, so the data directory
#     is bind-mounted read-only at ${CDATA} and {{DATA}} in load/ is substituted with that
#     in-container path, not the host one.
#   * The CSV must distinguish NULL from the empty string: it writes NULL as \N and an empty
#     string as a bare empty field, and the load statements say (FORMAT csv, NULL '\N'). With
#     empty fields standing in for NULL, Umbra rejects the file outright ("invalid number format
#     for integer: no digits found in \"\"", "invalid date literal ''") -- which is how most of
#     TPC-DS failed to load in the versions benchmark.
#   * DROP SCHEMA answers "DROP SCHEMA not implemented yet", and in a multi-statement batch that
#     error aborts the CREATE SCHEMA after it, leaving every CREATE TABLE to fail with
#     'schema "<ds>" does not exist'. The ddl/ files therefore use CREATE SCHEMA IF NOT EXISTS
#     plus a per-table DROP TABLE IF EXISTS, which is the same idempotence built out of
#     statements Umbra actually implements.
#   * pg_total_relation_size() does not exist, so data_size is du(1) on the database directory.
#   * It is mmap-heavy and will not start if its data dir is not writable, so the dir is created
#     0777 up front and the host gets the memory sysctls the main ClickBench umbra/start uses.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"
CDATA="/data"                                  # where ${DATA} is mounted inside the container
TRIES="${TRIES:-6}"                            # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1. Worth turning off when you only care about hot times, or on a host
# without passwordless sudo where the drop cannot work anyway: it costs ~1.5s per query, which at
# 238 queries is ~6 minutes per system and, at scale factor 1, more than the queries themselves.
# Turning it off makes the "cold" column meaningless, so the run announces which mode it used.
DROP_CACHES="${DROP_CACHES:-1}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
LOAD_TIMEOUT="${LOAD_TIMEOUT:-1200}"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"
PASSWORD="${PASSWORD:-postgres}"
# STATISTICS=1 runs one `ANALYZE "<schema>"."<table>"` per loaded table (see load_one_dataset);
# without it none run, and the load/*.sql files hold nothing but the COPYs. Off by default: it is
# extra work whose benefit only shows on some queries, and keeping it opt-in makes a
# with/against comparison possible on the same data. They are timed separately and reported as
# stats_time, not as part of load_time, so a STATISTICS=1 run stays load-time comparable with one
# without it.
STATISTICS="${STATISTICS:-}"
# KEEP_DATA=1 leaves the loaded data on disk when the run ends, for poking at it afterwards.
# Off by default so this system behaves like the container-based ones, whose data goes away with
# `docker rm -f`: at a large scale factor a leftover copy sits there while the next system loads,
# and the peak disk requirement doubles.
KEEP_DATA="${KEEP_DATA:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there -- no queries, and the server
# is LEFT RUNNING so you can drive it by hand. Nothing is torn down and no results file is
# written. Clean up yourself when done (the runner prints how). This is what the versions
# benchmark's `phase load` did.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a server that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1. Nothing is started and nothing is loaded, and it is LEFT RUNNING afterwards,
# so a run cannot destroy what it did not create; at a large scale factor an automatic teardown
# would cost a full reload. A results file is written exactly as a full run writes one, and a
# benchmark whose tables are not present reports null, as it would anywhere else.
#
# load_time is NOT measured by such a run. It is carried over from the last load recorded in
# LOAD_STATS, and the run says so on stderr, so a stale carry-over cannot pass unnoticed.
#
# This is the versions benchmark's `phase bench` (run-version.sh: PHASE=bench attaches to what the
# load phase left running). One deliberate difference: there, bench tore the container down when
# it finished.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi

SYSTEM="Umbra"
VERSION="26.08"
RELEASE_DATE="2026-08-01"   # release date of the pinned version, reported in the results
IMAGE="umbradb/umbra:26.08"
CONTAINER="dbbench_umbra"
DBDIR="${HERE}/.umbra"                         # database dir, bind-mounted at /var/db
# One file per run, never overwritten: the timestamp keeps a run of one benchmark from
# erasing another benchmark's timings, which matters when a large scale factor is run
# one benchmark at a time. generate-results.sh groups these by system and takes each
# benchmark's rows from the newest run that has them.
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
OUT="${ROOT}/results/umbra/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT, so a run's log and its results
# file pair by name. Written here rather than by run-all.sh, which is what left a
# stale single logs/umbra.log behind whenever the runner was invoked directly. The tee
# keeps stderr on the terminal as well, so a foreground run still shows progress.
LOG="${ROOT}/logs/umbra/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
LOAD_STATS="${ROOT}/logs/umbra.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/umbra.statstimes.tsv"
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

# psql over the host network from a throwaway client container. Umbra prints an INFO: line per
# statement (parsing/compilation/execution breakdown), which is noise here -- errors are matched
# on ERROR:/FATAL: instead, so INFO never trips them.
PG()  { docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
            psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 -tAc "$1" 2>&1; }
# A whole script on stdin: psql sends one statement at a time and, with ON_ERROR_STOP off (the
# default), carries on past a failing one -- so a DROP that finds nothing does not stop the
# CREATE after it.
PGscript() { docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
            psql -h127.0.0.1 -p5432 -U postgres -d postgres 2>&1; }
# No SET statement_timeout: Umbra rejects it outright ("cannot change configuration parameter
# statement_timeout"), and with ON_ERROR_STOP off that error still lands in the output, where it
# matches the ERROR: check and nulls the query -- in the versions benchmark it nulled all 238.
# So the only bound is the client-side `timeout`. That is weaker than a server-side cap -- killing
# psql leaves the statement running on the server -- but Umbra offers no server-side equivalent.
PGload() { timeout -k 10 "$((LOAD_TIMEOUT + 60))" docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" \
            "${PSQL_IMAGE}" psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 \
            -tAc "$1" 2>&1; }

# Drop the page cache so the first of the TRIES is genuinely cold rather than reading its own
# previous run's pages. Silently does nothing without passwordless sudo, which would make every
# try warm without saying so -- hence the announcement in announce_cache_mode.
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
pg_failed() { printf '%s' "$1" | grep -qE 'ERROR:|FATAL:'; }
fmt_err() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-200; }

start_server() {
    docker rm -fv "${CONTAINER}" >/dev/null 2>&1
    # Start from an empty database dir, as the ClickHouse (fresh container) and DuckDB (fresh
    # database file) runners do: load times and the du(1) sizes below only mean something when
    # nothing is already in there from a previous run.
    rm -rf "${DBDIR}" 2>/dev/null || sudo rm -rf "${DBDIR}"
    # Create the bind-mount source FIRST: Docker auto-creates a missing one as root, and Umbra
    # needs /var/db writable -- it fails with "unable to acquire flock on /var/db/umbra.db.lock"
    # otherwise.
    mkdir -p "${DBDIR}"
    chmod 777 "${DBDIR}"
    # Umbra issues a large number of small mmaps and expects to page rather than be capped; the
    # main ClickBench umbra/start sets the same three. No docker --memory cap on purpose: cgroup
    # v2 turns one into a hard OOM ceiling regardless of available swap.
    sudo sysctl -wq vm.overcommit_memory=1 vm.swappiness=100 vm.max_map_count=1048576 2>/dev/null || true
    echo "starting ${SYSTEM} ${VERSION} from image ${IMAGE}" >&2
    docker pull "${IMAGE}" >/dev/null 2>&1
    docker run -d --name "${CONTAINER}" --network host \
        -e CEDAR_PASSWORD="${PASSWORD}" \
        --ulimit nofile=1048576:1048576 --ulimit memlock=-1:-1 \
        -v "${DBDIR}:/var/db" -v "${DATA}:${CDATA}:ro" "${IMAGE}" >/dev/null || return 1
    local waited=0
    until PG 'SELECT 1' 2>/dev/null | grep -q '^1$'; do
        sleep 5; waited=$((waited + 5))
        if [ "${waited}" -gt 300 ]; then
            echo "Umbra did not come up in 300s; last log lines:" >&2
            docker logs --tail 20 "${CONTAINER}" >&2 2>&1 || true
            return 1
        fi
    done
    echo "Umbra up ($(actual_version))" >&2
}
# Stop the server AND remove its data directory, so the loaded data does not outlive the run --
# the container-based systems get that from `docker rm -f`, but Umbra's lives in a bind mount.
# sudo because Umbra's files in there are root-owned.
# -v, not just -f: several of these images declare a VOLUME at their data directory
# (clickhouse-server /var/lib/clickhouse, cedardb /var/lib/cedardb/data, umbra /var/db,
# firebolt-core /firebolt-core/volume). Docker creates an ANONYMOUS volume for that on every
# `docker run`, and removing the container without -v orphans it -- with the whole loaded dataset
# inside. That leaked 160 GB across earlier runs before anyone noticed.
stop_server() {
    docker rm -fv "${CONTAINER}" >/dev/null 2>&1
    if [ -n "${KEEP_DATA}" ]; then
        echo "KEEP_DATA=1: leaving ${DBDIR} in place" >&2
    else
        rm -rf "${DBDIR}" 2>/dev/null || sudo rm -rf "${DBDIR}" 2>/dev/null || true
    fi
}

actual_version() { PG 'SELECT version()' 2>/dev/null | head -1; }

# pg_total_relation_size() does not exist in Umbra, so measure the database dir instead: a
# benchmark's size is how much the dir grew while it loaded. sudo because Umbra's files in there
# are root-owned.
db_size() { sudo du -bs "${DBDIR}" 2>/dev/null | awk '{print $1+0; exit}'; }

# Load one benchmark: the schema and tables from ddl/, then the COPY statements from load/, one
# at a time so a failing table is named in the log and gets its own timeout.
load_one_dataset() {
    local ds="$1" stmt out t0 before after ok=1 rc table
    t0=${SECONDS}; before="$(db_size)"
    echo "=== CREATE ${ds} tables ===" >&2
    out=$(PGscript < "${HERE}/ddl/${ds}.sql")
    if pg_failed "${out}"; then
        echo "CREATE ${ds} FAILED: $(fmt_err "${out}")" >&2; return 1
    fi
    echo "=== LOAD ${ds} ===" >&2
    # Read the load script on FD 3, not stdin: every psql call below runs via `docker run -i`
    # and would otherwise consume the rest of the script.
    while IFS= read -r stmt <&3; do
        case "${stmt}" in ''|--*) continue ;; esac
        echo "=== ${stmt:0:120} ===" >&2
        out=$(PGload "${stmt}"); rc=$?
        if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
            echo "LOAD ${ds} TIMED OUT after ${LOAD_TIMEOUT}s: ${stmt:0:100}" >&2; ok=0
        elif pg_failed "${out}"; then
            echo "LOAD ${ds} FAILED: $(fmt_err "${out}")" >&2; ok=0
        fi
    done 3< <(sed -e "s#{{DATA}}#${CDATA}#g" "${HERE}/load/${ds}.sql")
    # Statistics are timed SEPARATELY and reported as stats_time; they are NOT folded into
    # load_time. At TPC-H SF100 the ClickHouse lineitem ALTER alone is ~570s against a ~1200s
    # load, so including it made a STATISTICS=1 load_time incomparable with a run without it.
    # A failure is still logged and ignored: the data is loaded either way.
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
        after="$(db_size)"
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" "$(( ${after:-0} - ${before:-0} ))" >> "${LOAD_STATS}"
        echo "loaded ${ds} in $((SECONDS - t0))s" >&2
    fi
}

# True only if EVERY table of this benchmark exists and holds at least one row. If any table
# failed to load, the benchmark is not benchmarked and neither its load time nor its size is
# reported.
dataset_fully_loaded() {
    local ds="$1" table cnt out
    for table in ${TABLES[$ds]}; do
        # Check for an error BEFORE parsing a count. Scraping digits out of the whole output
        # (tr -cd '0-9') reads an error message as a row count -- "ERROR 1146 (42S02)" and
        # 'ERROR: relation "x" does not exist LINE 1:' both contain digits -- so a benchmark
        # that was never loaded reported itself fully loaded, and its queries then ran against
        # missing tables instead of being recorded null. Require a line that is ONLY digits.
        out=$(PG "SELECT count(*) FROM \"${ds}\".\"${table}\";" 2>&1)
        pg_failed "${out}" && return 1
        printf '%s' "${out}" | grep -qiE 'does not exist' && return 1
        cnt=$(printf '%s' "${out}" | grep -oxE '[[:space:]]*[0-9]+[[:space:]]*' | tr -cd '0-9' | head -1)
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

# A results row of all-null, for a query that was never run.
null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times in a SINGLE psql session (so the first run is cold -- dropped OS
# cache -- and the rest are hot) and time it with psql's \timing: "Time: <ms> ms" per statement,
# converted to seconds. The search_path is set before \timing so it is not itself timed. A query
# that errors nulls the whole row: if any error surfaced, none of the printed timings can be
# trusted. No statement_timeout here either (see PGload) -- the client-side timeout is the only
# bound, and it covers all TRIES at once because they share one session.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" script out reals=()
    script="SET search_path TO \"${ds}\";"$'\n'"\\timing on"$'\n'
    local i
    for i in $(seq 1 "${TRIES}"); do script+="${query};"$'\n'; done
    drop_caches
    out=$(printf '%s' "${script}" | timeout -k 10 "$((QUERY_TIMEOUT * TRIES + 120))" \
          docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
          psql -h127.0.0.1 -p5432 -U postgres -d postgres 2>&1)
    if printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
        echo "${label}: FAILED: $(printf '%s' "${out}" | grep -E 'ERROR:|FATAL:' | head -1 | cut -c1-160)" >&2
        null_row; return
    fi
    mapfile -t reals < <(printf '%s' "${out}" | grep -oE 'Time: [0-9.]+ ms' | grep -oE '[0-9.]+' \
        | awk '{printf "%.3f\n", $1/1000}')
    if [ "${#reals[@]}" -eq 0 ]; then
        echo "${label}: no timing (server may have crashed)" >&2
        null_row; return
    fi
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
emit_data_size_json() {  # $1 = fully-loaded benchmarks
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$3} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

# Time every query and write results/umbra.json.
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
            # Read queries on FD 3 (not stdin) so the per-query `docker run -i` psql calls
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
}

# ---- run ----
announce_cache_mode
if [ -n "${QUERY_ONLY}" ]; then
    trap - EXIT                       # this run did not start it, so it must not tear it down
    PG 'SELECT 1' 2>/dev/null | grep -q '^1$' || {
        echo "QUERY_ONLY=1, but Umbra is not answering. Start one and load it with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1; }
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "server left running (this run did not start it). Tear down with:" >&2
    echo "    docker rm -fv ${CONTAINER} && sudo rm -rf ${DBDIR}" >&2
    exit 0
fi

trap stop_server EXIT
start_server || { echo "cannot start Umbra ${VERSION}" >&2; exit 1; }
: > "${LOAD_STATS}"; : > "${STAT_STATS}"
for ds in ${LOAD_DATASETS}; do load_one_dataset "${ds}" || true; done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # leave it up; do not tear anything down
    echo "server left running on 127.0.0.1:5432. Connect with:" >&2
    echo "    PGPASSWORD=${PASSWORD} psql -h127.0.0.1 -p5432 -U postgres -d postgres" >&2
    echo "    (then: SET search_path TO <benchmark>;)" >&2
    echo "Tear down with: docker rm -fv ${CONTAINER} && sudo rm -rf ${DBDIR}" >&2
    exit 0
fi
run_benchmark
