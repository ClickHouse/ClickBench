#!/usr/bin/env bash
# Benchmark one CedarDB version. Runs the official image (PostgreSQL wire protocol), loads
# the prepared Parquet (see ../prepare-parquet.sh) with CREATE TABLE AS SELECT * FROM
# '<file>.parquet', times every query with psql's \timing, and writes results/<version>.json
# in the same shape as the ClickHouse runner.
#
#   ./run-version.sh <version> [image] [phase]
#
# version + image come from versions.tsv. Each dataset loads into its own schema because
# TPC-H and TPC-DS both define a `customer` table. psql is not required on the host: it runs
# from a small postgres client image over the host network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"                      # versions/
# CedarDB reads a dedicated Parquet variant (FixedString->String, UInt*->signed Int): its
# reader rejects char(N) and its unsigned aggregation overflows. Auto-generated below.
PARQUET="${PARQUET:-${ROOT}/prepare-data/parquet-cedar}"
TRIES="${TRIES:-6}"                                    # 1 cold + 5 hot
QUERY_TIMEOUT="${QUERY_TIMEOUT:-120}"
LOAD_DATASETS="${LOAD_DATASETS:-hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"
QUERY_ORDER="mgbench ssb hits uk ontime taxi coffeeshop tpch tpcds job"
PSQL_IMAGE="${PSQL_IMAGE:-postgres:16-alpine}"

VERSION="${1:?usage: run-version.sh <version> [image] [phase]}"
IMAGE="${2:-}"
PHASE="${3:-all}"
[ -z "${IMAGE}" ] && IMAGE="$(awk -F'\t' -v v="${VERSION}" '$1==v{print $2}' "${HERE}/versions.tsv")"
[ -z "${IMAGE}" ] && { echo "no image for CedarDB ${VERSION} in versions.tsv" >&2; exit 1; }

CONTAINER="cedar-${VERSION}"
CPARQUET="/parquet"                                    # where PARQUET is mounted in the container
PASSWORD="cedar"
OUT="${HERE}/results/${VERSION}.json"
LOAD_STATS="${HERE}/logs/${VERSION}.loadtimes.tsv"
mkdir -p "${HERE}/logs" "${HERE}/results"

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

# psql over the host network from a throwaway client container (host needs no psql). -q reads
# a script from stdin. PG() runs one statement, tuples-only; PGscript() pipes a full script.
PG()       { docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
                psql -h127.0.0.1 -p5432 -U postgres -d postgres -v ON_ERROR_STOP=0 -tAc "$1" 2>&1; }
PGscript() { docker run --rm -i --network host -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" \
                psql -h127.0.0.1 -p5432 -U postgres -d postgres 2>&1; }

drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1; }
parquet_path() { printf '%s/%s.parquet' "${CPARQUET}" "$1"; }

start_server() {
    docker rm -f "${CONTAINER}" >/dev/null 2>&1
    echo "starting CedarDB ${VERSION} (${IMAGE})" >&2
    docker run -d --name "${CONTAINER}" -e CEDAR_PASSWORD="${PASSWORD}" -p 5432:5432 \
        -v "${PARQUET}:${CPARQUET}:ro" "${IMAGE}" >/dev/null || return 1
    local waited=0
    until PG 'SELECT 1' 2>/dev/null | grep -q '^1$'; do
        sleep 3; waited=$((waited + 3))
        [ "${waited}" -gt 180 ] && { echo "CedarDB did not come up in 180s" >&2; return 1; }
    done
    echo "CedarDB up ($(PG 'SELECT version()' 2>/dev/null | head -1))" >&2
}
stop_server() { docker rm -f "${CONTAINER}" >/dev/null 2>&1; }

# Load one dataset: a schema per dataset, each table via CREATE TABLE AS SELECT FROM '<file>'.
load_one_dataset() {
    local ds="$1" pair table pq out t0 ok=1
    PG "DROP SCHEMA IF EXISTS \"${ds}\" CASCADE; CREATE SCHEMA \"${ds}\";" >/dev/null 2>&1
    t0=${SECONDS}
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; pq="$(parquet_path "${pair##*:}")"
        echo "=== CREATE ${ds}.${table} FROM ${pair##*:}.parquet ===" >&2
        out=$(PG "CREATE TABLE \"${ds}\".\"${table}\" AS SELECT * FROM '${pq}';")
        if printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
            echo "LOAD ${ds}.${table} FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)" >&2; ok=0
        fi
    done
    if [ "${ok}" = 1 ]; then
        local bytes
        bytes=$(PG "SELECT COALESCE(SUM(pg_total_relation_size(c.oid)),0) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='${ds}' AND c.relkind='r';" 2>/dev/null | tr -cd '0-9')
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0))" "${bytes:-0}" >> "${LOAD_STATS}"
    fi
}

dataset_fully_loaded() {
    local ds="$1" pair table out cnt
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"
        # PG() merges stderr, so a missing table yields an error whose text ("logs1") contains
        # digits -- extract only a line that is purely a number, and bail on any error.
        out=$(PG "SELECT count(*) FROM \"${ds}\".\"${table}\";")
        printf '%s' "${out}" | grep -qiE 'error|does not exist' && return 1
        cnt=$(printf '%s' "${out}" | grep -oxE '[0-9]+' | head -1)
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times in ONE psql session (first cold, rest hot). psql's \timing prints
# "Time: X.XXX ms" per statement. search_path is set BEFORE \timing so only the query is
# timed; a query that errors prints an ERROR (and no/garbage timing) -> null the whole row.
run_query() {
    local ds="$1" query="$2" label="${3:-query}" i script out reals
    drop_caches
    script="SET search_path TO \"${ds}\";"$'\n'"\\timing on"$'\n'
    for i in $(seq 1 "${TRIES}"); do script+="${query};"$'\n'; done
    out=$(printf '%s' "${script}" | timeout "${QUERY_TIMEOUT}" docker run --rm -i --network host \
          -e PGPASSWORD="${PASSWORD}" "${PSQL_IMAGE}" psql -h127.0.0.1 -p5432 -U postgres -d postgres 2>&1)
    # Match psql's error prefix ("ERROR:"/"FATAL:"), not "error" in result data.
    if printf '%s' "${out}" | grep -qE 'ERROR:|FATAL:'; then
        echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oE '(ERROR|FATAL):[^|]*' | head -1 | cut -c1-160)" >&2
        null_row; return
    fi
    mapfile -t reals < <(printf '%s' "${out}" | grep -oiE 'Time:[[:space:]]+[0-9.]+[[:space:]]*ms' | grep -oE '[0-9.]+')
    local res="[" v
    for i in $(seq 1 "${TRIES}"); do
        v="${reals[$((i-1))]:-}"
        if [ -n "${v}" ]; then v=$(awk -v x="${v}" 'BEGIN{printf "%.4f", x/1000}'); else v="null"; fi
        res+="${v}"; [ "${i}" -ne "${TRIES}" ] && res+=", "
    done
    echo "${res}]"
}

actual_version() { PG 'SELECT version()' 2>/dev/null | head -1; }
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
    echo "benchmarking CedarDB ${VERSION} (reports ${ACTUAL:-unknown}, released ${RELEASE:-unknown})" >&2
    for ds in ${QUERY_ORDER}; do dataset_fully_loaded "${ds}" && FULLY_LOADED+=" ${ds}" \
        || echo "=== ${ds}: not fully loaded; skipping ===" >&2; done
    {
        echo '{'
        echo "    \"system\": \"CedarDB\","
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
# Generate any missing CedarDB-typed Parquet for the datasets we will load (idempotent).
bases=""
for ds in ${LOAD_DATASETS}; do
    [ -f "${HERE}/queries/${ds}.sql" ] || continue
    for pair in ${TABLES[$ds]}; do bases+=" ${pair##*:}"; done
done
CEDAR=1 PARQUET="${PARQUET}" bash "${ROOT}/prepare-parquet.sh" ${bases} >&2 || true
start_server || { echo "cannot start CedarDB ${VERSION}" >&2; exit 1; }
: > "${LOAD_STATS}"
for ds in ${LOAD_DATASETS}; do
    [ -f "${HERE}/queries/${ds}.sql" ] || continue
    load_one_dataset "${ds}"
done
run_benchmark
