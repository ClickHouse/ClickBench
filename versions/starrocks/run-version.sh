#!/usr/bin/env bash
# Benchmark one StarRocks version. Runs the official all-in-one image (FE+BE in one
# container), loads the prepared Parquet (see ../prepare-parquet.sh) with CREATE TABLE AS
# SELECT * FROM FILES(...), times every query via the server-side query profile, and writes
# results/<version>.json in the same shape as the ClickHouse runner.
#
#   ./run-version.sh <version> [image] [phase]
#
# version + image come from versions.tsv. Each dataset loads into its own database
# (bench_<ds>) because TPC-H and TPC-DS both define a `customer` table.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"                      # versions/
PARQUET="${PARQUET:-${ROOT}/prepare-data/parquet}"
TRIES="${TRIES:-6}"                                    # 1 cold + 5 hot
QUERY_TIMEOUT="${QUERY_TIMEOUT:-120}"
LOAD_DATASETS="${LOAD_DATASETS:-hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"
QUERY_ORDER="mgbench ssb hits uk ontime taxi coffeeshop tpch tpcds job"

VERSION="${1:?usage: run-version.sh <version> [image] [phase]}"
IMAGE="${2:-}"
PHASE="${3:-all}"
[ -z "${IMAGE}" ] && IMAGE="$(awk -F'\t' -v v="${VERSION}" '$1==v{print $2}' "${HERE}/versions.tsv")"
[ -z "${IMAGE}" ] && { echo "no image for StarRocks ${VERSION} in versions.tsv" >&2; exit 1; }

CONTAINER="sr-${VERSION}"
CPARQUET="/parquet"                                    # where PARQUET is mounted in the container
OUT="${HERE}/results/${VERSION}.json"
LOAD_STATS="${HERE}/logs/${VERSION}.loadtimes.tsv"
mkdir -p "${HERE}/logs" "${HERE}/results"

# Dataset -> "table:parquet-basename ..." (same stems the ClickHouse runner uses).
declare -A TABLES=(
    [hits]="hits:hits"
    [ssb]="lineorder_flat:ssb"
    [mgbench]="logs1:mgbench1 logs2:mgbench2 logs3:mgbench3"
    [taxi]="trips:taxi"
    [tpch]="nation:tpch_nation region:tpch_region part:tpch_part supplier:tpch_supplier partsupp:tpch_partsupp customer:tpch_customer orders:tpch_orders lineitem:tpch_lineitem"
    [tpcds]="call_center:tpcds_call_center catalog_page:tpcds_catalog_page catalog_returns:tpcds_catalog_returns catalog_sales:tpcds_catalog_sales customer_address:tpcds_customer_address customer_demographics:tpcds_customer_demographics customer:tpcds_customer date_dim:tpcds_date_dim household_demographics:tpcds_household_demographics income_band:tpcds_income_band inventory:tpcds_inventory item:tpcds_item promotion:tpcds_promotion reason:tpcds_reason ship_mode:tpcds_ship_mode store_returns:tpcds_store_returns store_sales:tpcds_store_sales store:tpcds_store time_dim:tpcds_time_dim warehouse:tpcds_warehouse web_page:tpcds_web_page web_returns:tpcds_web_returns web_sales:tpcds_web_sales web_site:tpcds_web_site"
    [coffeeshop]="fact_sales:coffeeshop_fact_sales dim_locations:coffeeshop_dim_locations dim_products:coffeeshop_dim_products"
    [ontime]="ontime:ontime"
    [uk]="uk_price_paid:uk_price_paid"
    [job]="aka_name:job_aka_name aka_title:job_aka_title cast_info:job_cast_info char_name:job_char_name comp_cast_type:job_comp_cast_type company_name:job_company_name company_type:job_company_type complete_cast:job_complete_cast info_type:job_info_type keyword:job_keyword kind_type:job_kind_type link_type:job_link_type movie_companies:job_movie_companies movie_info:job_movie_info movie_info_idx:job_movie_info_idx movie_keyword:job_movie_keyword movie_link:job_movie_link name:job_name person_info:job_person_info role_type:job_role_type title:job_title"
)

# --- StarRocks client (mysql lives inside the image; talk to the FE over 127.0.0.1:9030) ---
M()  { docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N "$@"; }        # no column names
Mq() { M -e "$1"; }                                                                    # one statement

drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1; }
db_of() { printf 'bench_%s' "$1"; }
parquet_uri() { printf 'file://%s/%s.parquet' "${CPARQUET}" "$1"; }

# Start the container (mounting the Parquet dir read-only) and wait for a live FE + BE.
start_server() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1
    echo "starting StarRocks ${VERSION} (${IMAGE})" >&2
    docker run -d --name "${CONTAINER}" -p 9030:9030 -p 8030:8030 -p 8040:8040 \
        -v "${PARQUET}:${CPARQUET}:ro" "${IMAGE}" >/dev/null || return 1
    local waited=0
    until Mq 'SELECT 1' >/dev/null 2>&1; do
        sleep 5; waited=$((waited + 5))
        [ "${waited}" -gt 300 ] && { echo "FE did not come up in 300s" >&2; return 1; }
    done
    waited=0
    until [ "$(Mq 'SHOW BACKENDS' 2>/dev/null | awk -F'\t' '{print $9}' | grep -c true)" -ge 1 ]; do
        sleep 5; waited=$((waited + 5))
        [ "${waited}" -gt 300 ] && { echo "BE did not register in 300s" >&2; return 1; }
    done
    echo "StarRocks up ($(Mq 'SELECT current_version()' 2>/dev/null | head -1))" >&2
}
stop_server() { docker rm -f "${CONTAINER}" >/dev/null 2>&1; }

# Load one dataset: a database per dataset, each table via CREATE TABLE AS SELECT FROM FILES().
load_one_dataset() {
    local ds="$1" db pair table uri out t0 ok=1
    db="$(db_of "${ds}")"
    Mq "DROP DATABASE IF EXISTS ${db}; CREATE DATABASE ${db};" >/dev/null 2>&1
    t0=${SECONDS}
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; uri="$(parquet_uri "${pair##*:}")"
        echo "=== CREATE ${db}.${table} FROM ${pair##*:}.parquet ===" >&2
        out=$(Mq "CREATE TABLE ${db}.\`${table}\` AS SELECT * FROM FILES('path'='${uri}','format'='parquet');" 2>&1)
        if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
            echo "LOAD ${ds}.${table} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)" >&2; ok=0
        fi
    done
    if [ "${ok}" = 1 ]; then
        # data size: sum of on-disk data length for the database's tables
        local bytes
        bytes=$(Mq "SELECT IFNULL(SUM(DATA_LENGTH),0) FROM information_schema.tables WHERE TABLE_SCHEMA='${db}';" 2>/dev/null | tr -cd '0-9')
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0))" "${bytes:-0}" >> "${LOAD_STATS}"
    fi
}

dataset_fully_loaded() {
    local ds="$1" db pair table cnt
    db="$(db_of "${ds}")"
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"
        cnt=$(Mq "SELECT count(*) FROM ${db}.\`${table}\`;" 2>/dev/null | tr -cd '0-9')
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

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

# Run one query TRIES times. StarRocks caches data in the BE, so the profile Time is the
# server-side execution; the first run after load is the cold-ish one. We read the time from
# the query profile (enable_profile) rather than wall clock, to exclude client/connect cost.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" db i out t reals=()
    db="$(db_of "${ds}")"
    for i in $(seq 1 "${TRIES}"); do
        [ "${i}" = 1 ] && drop_caches
        out=$(timeout "${QUERY_TIMEOUT}" docker exec -i "${CONTAINER}" mysql -h127.0.0.1 -P9030 -uroot -N \
              -e "SET enable_profile=true; USE ${db}; ${query}; SHOW PROFILELIST LIMIT 1;" 2>&1)
        # Match MySQL's error signature ("ERROR <code> (SQLSTATE)"), not "error" in result data.
        if printf '%s' "${out}" | grep -qE 'ERROR [0-9]+ \('; then
            echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE 'ERROR [0-9].*' | head -1 | cut -c1-160)" >&2
            reals=(); break
        fi
        # last line = the PROFILELIST row: QueryId <tab> StartTime <tab> Time <tab> State <tab> Statement
        t=$(printf '%s' "${out}" | tail -1 | awk -F'\t' '{print $3}')
        reals+=("$(time_to_sec "${t}")")
    done
    if [ "${#reals[@]}" -eq 0 ]; then null_row; return; fi
    local res="["
    for i in $(seq 1 "${TRIES}"); do res+="${reals[$((i-1))]:-null}"; [ "${i}" -ne "${TRIES}" ] && res+=", "; done
    echo "${res}]"
}

actual_version() { Mq 'SELECT current_version()' 2>/dev/null | head -1; }
release_date()   { awk -F'\t' -v v="${VERSION}" '$1==v{print $3; exit}' "${HERE}/versions.tsv"; }

emit_load_time_json() {
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}
emit_data_size_json() {
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$3} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

run_benchmark() {
    local ACTUAL RELEASE ds query FIRST=1 qnum=0 row ds_loaded FULLY_LOADED=""
    ACTUAL="$(actual_version)"; RELEASE="$(release_date)"
    echo "benchmarking StarRocks ${VERSION} (reports ${ACTUAL:-unknown}, released ${RELEASE:-unknown})" >&2
    for ds in ${QUERY_ORDER}; do dataset_fully_loaded "${ds}" && FULLY_LOADED+=" ${ds}" \
        || echo "=== ${ds}: not fully loaded; skipping ===" >&2; done
    {
        echo '{'
        echo "    \"system\": \"StarRocks\","
        echo "    \"version\": \"${VERSION}\","
        echo "    \"actual_version\": \"${ACTUAL}\","
        echo "    \"release_date\": \"${RELEASE}\","
        echo "    \"load_time\": $(emit_load_time_json "${FULLY_LOADED}"),"
        echo "    \"data_size\": $(emit_data_size_json "${FULLY_LOADED}"),"
        echo '    "result":'
        echo '    ['
        for ds in ${QUERY_ORDER}; do
            [ -f "${HERE}/queries/${ds}.sql" ] || continue
            case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
            while IFS= read -r query <&3; do
                [ -z "${query}" ] && continue
                query="${query%;}"; qnum=$((qnum + 1))
                if [ "${ds_loaded}" = 0 ]; then row="$(null_row)"
                else row="$(run_query "${ds}" "${query}" "q${qnum} [${ds}]")"; echo "q${qnum} [${ds}]: ${row}" >&2; fi
                [ "${FIRST}" = 0 ] && echo ','; FIRST=0
                printf '%s' "${row}"
            done 3< "${HERE}/queries/${ds}.sql"
        done
        echo; echo '    ]'; echo '}'
    } > "${OUT}"
    echo "wrote ${OUT}" >&2; cat "${OUT}"
}

# ---- run ----
trap stop_server EXIT
start_server || { echo "cannot start StarRocks ${VERSION}" >&2; exit 1; }
: > "${LOAD_STATS}"
for ds in ${LOAD_DATASETS}; do
    [ -f "${HERE}/queries/${ds}.sql" ] || continue
    load_one_dataset "${ds}"
done
run_benchmark
