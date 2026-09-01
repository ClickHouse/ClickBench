#!/usr/bin/env bash
# Generate the data for all three benchmarks, once, as Parquet -- the single artifact every
# system loads. DuckDB does all of it:
#
#   TPC-H   INSTALL tpch;  CALL dbgen(sf=N)    the standard dbgen, via DuckDB's extension
#   TPC-DS  INSTALL tpcds; CALL dsdgen(sf=N)   the standard dsdgen, same
#   JOB     read_csv over the canonical IMDB snapshot (no generator: it is real data)
#
#   ./generate-data.sh                # all three, at the default scale
#   ./generate-data.sh tpch tpcds     # only these
#   SCALE=10 ./generate-data.sh tpch  # a different scale factor
#   CSV=0 ./generate-data.sh          # Parquet only, no CSV (skips Umbra's input; see CSV below)
#
# Output: data/parquet/<benchmark>/<table>.parquet, plus data/csv/<benchmark>/<table>.csv for
# Umbra.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUCKDB="${DUCKDB:-$(command -v duckdb || echo "$HOME/.local/bin/duckdb")}"
SCALE="${SCALE:-1}"                       # TPC-H / TPC-DS scale factor (spec: 1,10,30,100,...)
JOB_SRC="${JOB_SRC:-https://event.cwi.nl/da/job/imdb.tgz}"
# CSV=0 skips the CSV copies entirely. They exist for Umbra.
CSV="${CSV:-1}"
PARQUET="${HERE}/data/parquet"
CSVDIR="${HERE}/data/csv"
WORK="${HERE}/data/work"

COPY_THREADS="${COPY_THREADS:-4}"
COPY_MEMORY="${COPY_MEMORY:-32GB}"
COPY_TUNE="SET threads=${COPY_THREADS}; SET memory_limit='${COPY_MEMORY}';"
[ -x "${DUCKDB}" ] || { echo "duckdb not found; set DUCKDB=<path>" >&2; exit 1; }
mkdir -p "${PARQUET}" "${CSVDIR}" "${WORK}"

TPCH_TABLES="nation region part supplier partsupp customer orders lineitem"
TPCDS_TABLES="call_center catalog_page catalog_returns catalog_sales customer_address \
customer_demographics customer date_dim household_demographics income_band inventory item \
promotion reason ship_mode store_returns store_sales store time_dim warehouse web_page \
web_returns web_sales web_site"
JOB_TABLES="aka_name aka_title cast_info char_name comp_cast_type company_name company_type \
complete_cast info_type keyword kind_type link_type movie_companies movie_info movie_info_idx \
movie_keyword movie_link name person_info role_type title"

# A CSV copy of one table, for Umbra. NULL is written as \N so it stays distinguishable from an
# empty string, which is written as a bare empty field -- the same distinction the JOB source
# makes, and the reason allow_quoted_nulls is off above.
emit_csv() {
    [ "${CSV}" = 0 ] && return 0
    local bench="$1" table="$2" src="$3"
    local out="${CSVDIR}/${bench}/${table}.csv"
    mkdir -p "${CSVDIR}/${bench}"
    [ -f "${out}" ] && return 0
    "${DUCKDB}" -c "${COPY_TUNE} COPY (SELECT * FROM read_parquet('${src}')) TO '${out}.tmp'
                    (FORMAT csv, HEADER false, NULLSTR '\N');" >/dev/null
    mv "${out}.tmp" "${out}"
}

# TPC-H / TPC-DS: run the generator into a scratch database, then COPY each table out.
gen_tpc() {
    local bench="$1" ext="$2" call="$3" tables="$4" db="${WORK}/${1}.db" t out todo=""
    mkdir -p "${PARQUET}/${bench}"
    for t in ${tables}; do
        [ -f "${PARQUET}/${bench}/${t}.parquet" ] || todo="${todo} ${t}"
    done
    if [ -z "${todo}" ]; then
        echo "${bench}: all tables present, skipping"
    else
        echo "${bench}: generating scale factor ${SCALE}"
        rm -f "${db}"
        "${DUCKDB}" "${db}" -c "INSTALL ${ext}; LOAD ${ext}; CALL ${call}(sf=${SCALE});" >/dev/null
        for t in ${todo}; do
            out="${PARQUET}/${bench}/${t}.parquet"
            echo "  ${bench}.${t} -> ${t}.parquet"
            "${DUCKDB}" "${db}" -c "${COPY_TUNE}
                COPY (SELECT * FROM ${t}) TO '${out}.tmp' (FORMAT parquet);" >/dev/null
            mv "${out}.tmp" "${out}"
        done
        rm -f "${db}"
    fi
    for t in ${tables}; do emit_csv "${bench}" "${t}" "${PARQUET}/${bench}/${t}.parquet"; done
}

# JOB: the real IMDB snapshot, no scale factor. Column types are declared per table (below)
# because the CSV has no header and inference would guess. Nullability is left to the data;
# each system's ddl/ declares NOT NULL where the schema says so, and an actual NULL there fails
# the load loudly rather than silently becoming a type default.
gen_job() {
    local t csv out cols todo=""
    mkdir -p "${PARQUET}/job"
    for t in ${JOB_TABLES}; do
        [ -f "${PARQUET}/job/${t}.parquet" ] || todo="${todo} ${t}"
    done
    if [ -n "${todo}" ]; then
        if [ ! -f "${WORK}/.imdb-extracted" ]; then
            echo "job: downloading ${JOB_SRC}"
            curl -fSL "${JOB_SRC}" -o "${WORK}/imdb.tgz"
            echo "job: extracting"
            tar -xzf "${WORK}/imdb.tgz" -C "${WORK}"
            rm -f "${WORK}/imdb.tgz"
            touch "${WORK}/.imdb-extracted"
        fi
        for t in ${todo}; do
            csv="$(find "${WORK}" -name "${t}.csv" | head -1)"
            [ -n "${csv}" ] || { echo "job: ${t}.csv not found in the snapshot" >&2; exit 1; }
            cols="$(job_columns "${t}")"
            out="${PARQUET}/job/${t}.parquet"
            echo "  job.${t} -> ${t}.parquet"
            "${DUCKDB}" -c "${COPY_TUNE}
                COPY (SELECT * FROM read_csv('${csv}', header=false, escape='\\',
                quote='\"', allow_quoted_nulls=false, columns=${cols}))
                TO '${out}.tmp' (FORMAT parquet);" >/dev/null
            mv "${out}.tmp" "${out}"
        done
    else
        echo "job: all tables present, skipping"
    fi
    for t in ${JOB_TABLES}; do emit_csv job "${t}" "${PARQUET}/job/${t}.parquet"; done
}

# Column types for the JOB tables.
job_columns() {
    case "$1" in
    aka_name) echo "{'id': 'INTEGER', 'person_id': 'INTEGER', 'name': 'VARCHAR', 'imdb_index': 'VARCHAR', 'name_pcode_cf': 'VARCHAR', 'name_pcode_nf': 'VARCHAR', 'surname_pcode': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    aka_title) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'title': 'VARCHAR', 'imdb_index': 'VARCHAR', 'kind_id': 'INTEGER', 'production_year': 'INTEGER', 'phonetic_code': 'VARCHAR', 'episode_of_id': 'INTEGER', 'season_nr': 'INTEGER', 'episode_nr': 'INTEGER', 'note': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    cast_info) echo "{'id': 'INTEGER', 'person_id': 'INTEGER', 'movie_id': 'INTEGER', 'person_role_id': 'INTEGER', 'note': 'VARCHAR', 'nr_order': 'INTEGER', 'role_id': 'INTEGER'}" ;;
    char_name) echo "{'id': 'INTEGER', 'name': 'VARCHAR', 'imdb_index': 'VARCHAR', 'imdb_id': 'INTEGER', 'name_pcode_nf': 'VARCHAR', 'surname_pcode': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    comp_cast_type) echo "{'id': 'INTEGER', 'kind': 'VARCHAR'}" ;;
    company_name) echo "{'id': 'INTEGER', 'name': 'VARCHAR', 'country_code': 'VARCHAR', 'imdb_id': 'INTEGER', 'name_pcode_nf': 'VARCHAR', 'name_pcode_sf': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    company_type) echo "{'id': 'INTEGER', 'kind': 'VARCHAR'}" ;;
    complete_cast) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'subject_id': 'INTEGER', 'status_id': 'INTEGER'}" ;;
    info_type) echo "{'id': 'INTEGER', 'info': 'VARCHAR'}" ;;
    keyword) echo "{'id': 'INTEGER', 'keyword': 'VARCHAR', 'phonetic_code': 'VARCHAR'}" ;;
    kind_type) echo "{'id': 'INTEGER', 'kind': 'VARCHAR'}" ;;
    link_type) echo "{'id': 'INTEGER', 'link': 'VARCHAR'}" ;;
    movie_companies) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'company_id': 'INTEGER', 'company_type_id': 'INTEGER', 'note': 'VARCHAR'}" ;;
    movie_info) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'info_type_id': 'INTEGER', 'info': 'VARCHAR', 'note': 'VARCHAR'}" ;;
    movie_info_idx) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'info_type_id': 'INTEGER', 'info': 'VARCHAR', 'note': 'VARCHAR'}" ;;
    movie_keyword) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'keyword_id': 'INTEGER'}" ;;
    movie_link) echo "{'id': 'INTEGER', 'movie_id': 'INTEGER', 'linked_movie_id': 'INTEGER', 'link_type_id': 'INTEGER'}" ;;
    name) echo "{'id': 'INTEGER', 'name': 'VARCHAR', 'imdb_index': 'VARCHAR', 'imdb_id': 'INTEGER', 'gender': 'VARCHAR', 'name_pcode_cf': 'VARCHAR', 'name_pcode_nf': 'VARCHAR', 'surname_pcode': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    person_info) echo "{'id': 'INTEGER', 'person_id': 'INTEGER', 'info_type_id': 'INTEGER', 'info': 'VARCHAR', 'note': 'VARCHAR'}" ;;
    role_type) echo "{'id': 'INTEGER', 'role': 'VARCHAR'}" ;;
    title) echo "{'id': 'INTEGER', 'title': 'VARCHAR', 'imdb_index': 'VARCHAR', 'kind_id': 'INTEGER', 'production_year': 'INTEGER', 'imdb_id': 'INTEGER', 'phonetic_code': 'VARCHAR', 'episode_of_id': 'INTEGER', 'season_nr': 'INTEGER', 'episode_nr': 'INTEGER', 'series_years': 'VARCHAR', 'md5sum': 'VARCHAR'}" ;;
    *) echo "unknown JOB table: $1" >&2; return 1 ;;
    esac
}

WANT="${*:-tpch tpcds job}"
for b in ${WANT}; do
    case "${b}" in
        tpch)  gen_tpc tpch  tpch  dbgen  "${TPCH_TABLES}" ;;
        tpcds) gen_tpc tpcds tpcds dsdgen "${TPCDS_TABLES}" ;;
        job)   gen_job ;;
        *) echo "unknown benchmark: ${b} (tpch | tpcds | job)" >&2; exit 1 ;;
    esac
done
rm -rf "${WORK}"
echo
echo "parquet: $(find "${PARQUET}" -name '*.parquet' | wc -l) files, $(du -sh "${PARQUET}" | cut -f1)"
if [ "${CSV}" = 0 ]; then
    echo "csv:     skipped (CSV=0); Umbra cannot be loaded from this data"
else
    echo "csv:     $(find "${CSVDIR}" -name '*.csv' | wc -l) files, $(du -sh "${CSVDIR}" | cut -f1)"
fi
