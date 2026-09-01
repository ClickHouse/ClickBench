#!/usr/bin/env bash
# Benchmark DuckDB. No Docker, no server: download the pinned CLI binary, load the generated
# Parquet into a database file, time every query, and write results/duckdb.json in the same
# shape as every other runner here.
#
#   ./run.sh                    # tpch tpcds job
#   ./run.sh tpch               # one benchmark
#   STATISTICS=1 ./run.sh       # ANALYZE after loading (reported as stats_time)
#
# The schema and queries come from explicit SQL files.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DATA="${DATA:-${ROOT}/data}"
TRIES="${TRIES:-6}"                        # 1 cold + 5 hot
# DROP_CACHES=0 skips the page-cache drop before each query, so the first of the TRIES is no
# longer cold. Default 1.
DROP_CACHES="${DROP_CACHES:-1}"
QUERY_TIMEOUT="${QUERY_TIMEOUT:-300}"   # seconds
# Unlike the other runners, where LOAD_TIMEOUT bounds ONE statement, here it bounds an entire
# benchmark's load.
LOAD_TIMEOUT="${LOAD_TIMEOUT:-3600}"
# STATISTICS=1 runs ANALYZE after loading so the optimiser has statistics.
STATISTICS="${STATISTICS:-}"
# KEEP_DATA=1 leaves the loaded data on disk when the run ends, for poking at it afterwards.
KEEP_DATA="${KEEP_DATA:-}"
# LOAD_ONLY=1 starts the server, loads the data, and stops there.
LOAD_ONLY="${LOAD_ONLY:-}"
# QUERY_ONLY=1 runs ONLY the query phase, against a set of database files that is ALREADY up with data in it --
# typically one left behind by LOAD_ONLY=1.
QUERY_ONLY="${QUERY_ONLY:-}"
if [ -n "${LOAD_ONLY}" ] && [ -n "${QUERY_ONLY}" ]; then
    echo "LOAD_ONLY=1 and QUERY_ONLY=1 are mutually exclusive: one loads without querying, the" >&2
    echo "other queries without loading. Pick one." >&2
    exit 1
fi

SYSTEM="DuckDB"
VERSION="1.5.5"
RELEASE_DATE="2026-07-22"   # release date of the pinned version, reported in the results
CLI_URL="https://github.com/duckdb/duckdb/releases/download/v${VERSION}/duckdb_cli-linux-amd64.zip"

LOAD_DATASETS="${*:-tpch tpcds job}"
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

WORK="${HERE}/.duckdb"; mkdir -p "${WORK}" "${ROOT}/logs"
BIN="${WORK}/duckdb-${VERSION}"
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
OUT="${ROOT}/results/duckdb/${RUN_TS}.json"
# One log per run, named for the SAME timestamp as OUT.
LOG="${ROOT}/logs/duckdb/${RUN_TS}.log"
mkdir -p "$(dirname "${LOG}")"
exec 2> >(tee -a "${LOG}" >&2)
mkdir -p "$(dirname "${OUT}")"
LOAD_STATS="${ROOT}/logs/duckdb.loadtimes.tsv"
STAT_STATS="${ROOT}/logs/duckdb.statstimes.tsv"

# One database file per benchmark.
db_of() { printf '%s/db-%s.duckdb' "${WORK}" "$1"; }
DBFILE=":memory:"

ensure_binary() {
    [ -x "${BIN}" ] && return 0
    local zip="${WORK}/duckdb-${VERSION}.zip"
    echo "downloading DuckDB ${VERSION} CLI: ${CLI_URL}" >&2
    curl -fsSL "${CLI_URL}" -o "${zip}" || { echo "download failed" >&2; return 1; }
    ( cd "${WORK}" && unzip -oq "${zip}" && mv duckdb "${BIN}" ) || { echo "unzip failed" >&2; return 1; }
    chmod +x "${BIN}"; rm -f "${zip}"
    [ -x "${BIN}" ]
}

# All SQL goes over stdin. run_sql: run statement(s), return combined output. scalar: read one
# value cleanly (`.mode list` + no headers -> the bare value on the last non-empty line).
run_sql() { printf '%s\n' "$1" | "${BIN}" "${DBFILE}" 2>&1; }
scalar()  { printf '.mode list\n.headers off\n%s\n' "$1" | "${BIN}" "${DBFILE}" 2>/dev/null | grep -v '^$' | tail -1; }

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

# Load one benchmark: a fresh database file, the DDL from ddl/, then the INSERTs from load/.
# CHECKPOINT after so the file size reflects the data; record (benchmark, seconds, bytes).
load_one_dataset() {
    local ds="$1" t0 out after rc
    DBFILE="$(db_of "${ds}")"; rm -f "${DBFILE}"
    t0=${SECONDS}
    echo "=== CREATE ${ds} tables ===" >&2
    out=$(timeout "${LOAD_TIMEOUT}" "${BIN}" "${DBFILE}" < "${HERE}/ddl/${ds}.sql" 2>&1); rc=$?
    if [ "${rc}" -eq 124 ]; then
        echo "CREATE ${ds} TIMED OUT after ${LOAD_TIMEOUT}s" >&2; return 1
    fi
    if printf '%s' "${out}" | grep -q 'Error:'; then
        echo "CREATE ${ds} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'Error:[^|]*' | head -1 | cut -c1-160)" >&2
        return 1
    fi
    echo "=== LOAD ${ds} ===" >&2
    out=$(sed -e "s#{{DATA}}#${DATA}#g" "${HERE}/load/${ds}.sql" \
          | timeout "${LOAD_TIMEOUT}" "${BIN}" "${DBFILE}" 2>&1); rc=$?
    # A timeout MUST be checked by EXIT CODE.
    if [ "${rc}" -eq 124 ]; then
        echo "LOAD ${ds} TIMED OUT after ${LOAD_TIMEOUT}s -- data is PARTIAL; raise LOAD_TIMEOUT" >&2
        return 1
    fi
    if printf '%s' "${out}" | grep -q 'Error:'; then
        echo "LOAD ${ds} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'Error:[^|]*' | head -1 | cut -c1-160)" >&2
        return 1
    fi
    # Statistics are timed SEPARATELY and reported as stats_time.
    STATS_SECS=0
    if [ -n "${STATISTICS}" ]; then
        echo "=== ANALYZE ${ds} ===" >&2
        st0=${SECONDS}
        out=$(printf 'ANALYZE;\n' | timeout "${LOAD_TIMEOUT}" "${BIN}" "${DBFILE}" 2>&1)
        printf '%s' "${out}" | grep -q 'Error:' \
            && echo "statistics on ${ds} failed: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-140)" >&2
        STATS_SECS=$((SECONDS - st0))
        printf '%s\t%s\n' "${ds}" "${STATS_SECS}" >> "${STAT_STATS}"
        echo "statistics on ${ds}: ${STATS_SECS}s" >&2
    fi
    printf 'CHECKPOINT;\n' | timeout "${LOAD_TIMEOUT}" "${BIN}" "${DBFILE}" >/dev/null 2>&1
    after=$(stat -c%s "${DBFILE}" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0 - STATS_SECS))" "${after}" >> "${LOAD_STATS}"
    echo "loaded ${ds} in $((SECONDS - t0 - STATS_SECS))s, ${after} bytes" >&2
}

# True if every table of the benchmark exists and is non-empty.
dataset_fully_loaded() {
    local ds="$1" table cnt raw
    DBFILE="$(db_of "${ds}")"
    if [ ! -f "${DBFILE}" ]; then
        echo "${ds}: no database file at ${DBFILE}" >&2
        return 1
    fi
    for table in ${TABLES[$ds]}; do
        # Require a digits-only answer.
        raw=$(printf '.mode list\n.headers off\nSELECT count(*) FROM "%s";\n' "${table}" \
              | "${BIN}" "${DBFILE}" 2>&1)
        cnt=$(printf '%s' "${raw}" | grep -v '^$' | tail -1 | grep -oxE '[0-9]+' | head -1)
        if [ -z "${cnt}" ]; then
            echo "${ds}: count(*) on ${table} gave no number; DuckDB said: $(printf '%s' "${raw}" | tr '\n' ' ' | cut -c1-200)" >&2
            return 1
        fi
        if [ "${cnt}" = "0" ]; then
            echo "${ds}: ${table} is empty (0 rows)" >&2
            return 1
        fi
    done
    return 0
}

null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times in a SINGLE DuckDB session (so the first run is cold -- fresh
# process + dropped OS cache -- and the rest are hot on the warm buffer pool).
run_query() {
    local query="$1" label="${2:-query}" i script out reals rc budget
    drop_caches
    script=".timer on"$'\n'
    for i in $(seq 1 "${TRIES}"); do script+="${query};"$'\n'; done
    # The budget must cover ALL TRIES, because every try runs in this ONE DuckDB session.
    budget=$((QUERY_TIMEOUT * TRIES + 60))
    out=$(printf '%s' "${script}" | timeout -k 10 "${budget}" "${BIN}" "${DBFILE}" 2>&1); rc=$?
    # Report a killed session explicitly.
    if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
        echo "${label}: FAILED (timeout: ${TRIES} tries exceeded ${budget}s total)" >&2
    fi
    if printf '%s' "${out}" | grep -q 'Error:'; then
        echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'Error:[^|]*' | head -1 | cut -c1-160)" >&2
        null_row; return
    fi
    mapfile -t reals < <(printf '%s' "${out}" | grep -oiE 'real[[:space:]]+[0-9.]+' | grep -oE '[0-9.]+')
    if [ "${#reals[@]}" -eq 0 ]; then
        echo "${label}: FAILED: (no timing)" >&2
    fi
    local res="["
    for i in $(seq 1 "${TRIES}"); do
        res+="${reals[$((i-1))]:-null}"; [ "${i}" -ne "${TRIES}" ] && res+=", "
    done
    echo "${res}]"
}

actual_version() { DBFILE=":memory:"; scalar "SELECT version();" | tr -d '"[:space:]'; }

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
            DBFILE="$(db_of "${ds}")"
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
                    row="$(run_query "${query}" "q${qnum} [${ds}]")"
                    echo "q${qnum} [${ds}]: ${row}" >&2
                fi
                [ "${FIRST}" = 0 ] && echo ','
                FIRST=0
                printf '        %s' "${row}"
            done 3< "${HERE}/queries/${ds}.sql"
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

# Remove this run's database files.
cleanup() {
    [ -n "${KEEP_DATA}" ] && { echo "KEEP_DATA=1: leaving ${DBDIR:-${WORK}}/db-*.duckdb in place" >&2; return 0; }
    local ds
    for ds in ${LOAD_DATASETS}; do rm -f "$(db_of "${ds}")"; done
}

# ---- run ----
trap cleanup EXIT
announce_cache_mode
if [ -n "${QUERY_ONLY}" ]; then
    trap - EXIT                       # this run did not start it, so it must not tear it down
    # DuckDB has no server, so "already loaded" means the database FILES are on disk.
    # run_benchmark checks each benchmark's tables itself (dataset_fully_loaded opens the file),
    # so all that is needed up front is the binary and at least one database file to open.
    ensure_binary || { echo "QUERY_ONLY=1, but the DuckDB binary is unavailable." >&2; exit 1; }
    if ! ls $(db_of '*') >/dev/null 2>&1; then
        echo "QUERY_ONLY=1, but no database files match $(db_of '*'). Load some with:" >&2
        echo "    LOAD_ONLY=1 ./run.sh [benchmark ...]" >&2
        exit 1
    fi
    if [ -s "${LOAD_STATS}" ]; then
        echo "QUERY_ONLY=1: load_time CARRIED OVER from ${LOAD_STATS}; this run loaded nothing" >&2
    else
        echo "QUERY_ONLY=1: no load times on record, so load_time will be empty" >&2
    fi
    run_benchmark
    echo "database files kept: $(db_of "${LOAD_DATASETS%% *}") and siblings" >&2
    exit 0
fi

ensure_binary || exit 1
: > "${LOAD_STATS}"; : > "${STAT_STATS}"
for ds in ${LOAD_DATASETS}; do load_one_dataset "${ds}" || true; done
if [ -n "${LOAD_ONLY}" ]; then
    trap - EXIT                       # keep the database files
    echo "no server to leave running; the database files are kept:" >&2
    for ds in ${LOAD_DATASETS}; do echo "    $(db_of "${ds}")" >&2; done
    echo "Open one with: ${BIN} $(db_of "${LOAD_DATASETS%% *}")" >&2
    exit 0
fi
run_benchmark
