#!/usr/bin/env bash
# Benchmark one DuckDB version. No Docker, no server: download that release's CLI binary,
# load the prepared Parquet (see ../prepare-parquet.sh) into a DuckDB database file, time
# every query, and write results/<version>.json in the same shape as the ClickHouse runner.
#
#   ./run-version.sh <version> [cli_url] [phase]
#
# version + cli_url come from versions.tsv (the CLI zip URL). Everything is local, so there
# is no load/bench split -- phase is accepted but only "all" is meaningful.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"          # versions/
PARQUET="${PARQUET:-${ROOT}/prepare-data/parquet}"
TRIES="${TRIES:-6}"                        # 1 cold + 5 hot
QUERY_TIMEOUT="${QUERY_TIMEOUT:-120}"
LOAD_DATASETS="${LOAD_DATASETS:-hits ssb mgbench tpch tpcds coffeeshop ontime uk job taxi}"
QUERY_ORDER="mgbench ssb hits uk ontime taxi coffeeshop tpch tpcds job"

VERSION="${1:?usage: run-version.sh <version> [cli_url] [phase]}"
CLI_URL="${2:-}"
PHASE="${3:-all}"
[ -z "${CLI_URL}" ] && CLI_URL="$(awk -F'\t' -v v="${VERSION}" '$1==v{print $2}' "${HERE}/versions.tsv")"
[ -z "${CLI_URL}" ] && { echo "no CLI url for DuckDB ${VERSION} in versions.tsv" >&2; exit 1; }

WORK="${HERE}/.duckdb"; mkdir -p "${WORK}" "${HERE}/logs"
BIN="${WORK}/duckdb-${VERSION}"
DBFILE="${WORK}/db-${VERSION}.duckdb"
OUT="${HERE}/results/${VERSION}.json"

# Each dataset's tables -> the Parquet basename to load it from (same stems the ClickHouse
# runner uses, minus the extension). One table per parquet file.
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

LOAD_STATS="${HERE}/logs/${VERSION}.loadtimes.tsv"

# Download + unpack the release CLI binary for this version (cached).
ensure_binary() {
    [ -x "${BIN}" ] && return 0
    local zip="${WORK}/duckdb-${VERSION}.zip"
    echo "downloading DuckDB ${VERSION} CLI: ${CLI_URL}" >&2
    curl -fsSL "${CLI_URL}" -o "${zip}" || { echo "download failed" >&2; return 1; }
    ( cd "${WORK}" && unzip -oq "${zip}" && mv duckdb "${BIN}" ) || { echo "unzip failed" >&2; return 1; }
    chmod +x "${BIN}"; rm -f "${zip}"
    [ -x "${BIN}" ]
}

# Run SQL non-interactively against the db file; args after the SQL go to the CLI.
duck() { "${BIN}" "${DBFILE}" "$@"; }

drop_caches() { sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1; }

parquet_of() { printf '%s/%s.parquet' "${PARQUET}" "$1"; }

# Load one dataset: CREATE TABLE <t> AS SELECT * FROM read_parquet(<file>) for each table.
# CHECKPOINT after, and record (dataset, seconds, bytes-added-to-db-file).
load_one_dataset() {
    local ds="$1" pair table pq t0 before after ok=1
    before=$(stat -c%s "${DBFILE}" 2>/dev/null || echo 0)
    t0=${SECONDS}
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"; pq="$(parquet_of "${pair##*:}")"
        [ -f "${pq}" ] || { echo "SKIP ${ds}.${table}: ${pq} missing" >&2; ok=0; continue; }
        echo "=== CREATE ${ds}.${table} FROM ${pq##*/} ===" >&2
        if ! duck -c "CREATE OR REPLACE TABLE \"${table}\" AS SELECT * FROM read_parquet('${pq}');" >&2 2>&1; then
            echo "LOAD ${ds}.${table} FAILED" >&2; ok=0
        fi
    done
    duck -c "CHECKPOINT;" >/dev/null 2>&1
    after=$(stat -c%s "${DBFILE}" 2>/dev/null || echo 0)
    if [ "${ok}" = 1 ]; then
        printf '%s\t%s\t%s\n' "${ds}" "$((SECONDS - t0))" "$((after - before))" >> "${LOAD_STATS}"
    fi
}

# True if every table of the dataset exists and is non-empty.
dataset_fully_loaded() {
    local ds="$1" pair table cnt
    for pair in ${TABLES[$ds]}; do
        table="${pair%%:*}"
        cnt=$("${BIN}" "${DBFILE}" -csv -noheader -c "SELECT count(*) FROM \"${table}\";" 2>/dev/null | tr -d '[:space:]')
        [ -n "${cnt}" ] && [ "${cnt}" != "0" ] || return 1
    done
    return 0
}

null_row() { local i out="["; for i in $(seq 1 "${TRIES}"); do out+="null"; [ "${i}" -ne "${TRIES}" ] && out+=", "; done; echo "${out}]"; }

# Run one query TRIES times in a SINGLE DuckDB session (so the first run is cold -- fresh
# process + dropped OS cache -- and the rest are hot on the warm buffer pool). Parse the
# TRIES timings DuckDB prints with `.timer on` ("Run Time (s): real X"). A query that errors
# prints no timing for that run -> null.
run_query() {
    local query="$1" label="${2:-query}" i script out reals
    drop_caches
    script=".timer on"$'\n'
    for i in $(seq 1 "${TRIES}"); do script+="${query};"$'\n'; done
    out=$(printf '%s' "${script}" | timeout "${QUERY_TIMEOUT}" "${BIN}" "${DBFILE}" 2>&1)
    mapfile -t reals < <(printf '%s' "${out}" | grep -oiE 'real[[:space:]]+[0-9.]+' | grep -oE '[0-9.]+')
    if [ "${#reals[@]}" -eq 0 ]; then
        echo "${label}: FAILED: $(printf '%s' "${out}" | tr '\n' ' ' | grep -oiE 'Error:.*' | cut -c1-160)" >&2
    fi
    local res="["
    for i in $(seq 1 "${TRIES}"); do
        res+="${reals[$((i-1))]:-null}"; [ "${i}" -ne "${TRIES}" ] && res+=", "
    done
    echo "${res}]"
}

actual_version() { "${BIN}" "${DBFILE}" -csv -noheader -c "SELECT version();" 2>/dev/null | tr -d '"[:space:]'; }
release_date()   { awk -F'\t' -v v="${VERSION}" '$1==v{print $3; exit}' "${HERE}/versions.tsv"; }

emit_load_time_json() {  # $1 = fully-loaded datasets
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$2} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}
emit_data_size_json() {  # $1 = fully-loaded datasets
    local loaded=" ${1:-} "
    [ -s "${LOAD_STATS}" ] && awk -F'\t' -v L="${loaded}" 'index(L," "$1" ")>0{s[$1]+=$3} END{printf "{"; for(d in s)printf "%s\"%s\": %s",(n++?", ":""),d,s[d]; printf "}"}' "${LOAD_STATS}" || printf '{}'
}

run_benchmark() {
    local ACTUAL RELEASE ds query FIRST=1 qnum=0 row ds_loaded FULLY_LOADED=""
    ACTUAL="$(actual_version)"; RELEASE="$(release_date)"
    echo "benchmarking DuckDB ${VERSION} (reports ${ACTUAL:-unknown}, released ${RELEASE:-unknown})" >&2
    for ds in ${QUERY_ORDER}; do dataset_fully_loaded "${ds}" && FULLY_LOADED+=" ${ds}" \
        || echo "=== ${ds}: not fully loaded; skipping ===" >&2; done
    {
        echo '{'
        echo "    \"system\": \"DuckDB\","
        echo "    \"version\": \"${VERSION}\","
        echo "    \"actual_version\": \"${ACTUAL}\","
        echo "    \"release_date\": \"${RELEASE}\","
        echo "    \"load_time\": $(emit_load_time_json "${FULLY_LOADED}"),"
        echo "    \"data_size\": $(emit_data_size_json "${FULLY_LOADED}"),"
        echo '    "result":'
        echo '    ['
        for ds in ${QUERY_ORDER}; do
            [ -f "${HERE}/queries/${ds}.sql" ] || continue   # only datasets with a query set (yet)
            case " ${FULLY_LOADED} " in *" ${ds} "*) ds_loaded=1 ;; *) ds_loaded=0 ;; esac
            while IFS= read -r query <&3; do
                [ -z "${query}" ] && continue
                query="${query%;}"; qnum=$((qnum + 1))
                if [ "${ds_loaded}" = 0 ]; then row="$(null_row)"
                else row="$(run_query "${query}" "q${qnum} [${ds}]")"; echo "q${qnum} [${ds}]: ${row}" >&2; fi
                [ "${FIRST}" = 0 ] && echo ','; FIRST=0
                printf '%s' "${row}"
            done 3< "${HERE}/queries/${ds}.sql"
        done
        echo; echo '    ]'; echo '}'
    } > "${OUT}"
    echo "wrote ${OUT}" >&2; cat "${OUT}"
}

# ---- run ----
ensure_binary || { echo "cannot obtain DuckDB ${VERSION}" >&2; exit 1; }
rm -f "${DBFILE}"; : > "${LOAD_STATS}"
for ds in ${LOAD_DATASETS}; do
    [ -f "${HERE}/queries/${ds}.sql" ] || continue     # only datasets we have queries for
    load_one_dataset "${ds}"
done
run_benchmark
