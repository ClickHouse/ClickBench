#!/usr/bin/env bash
# Prepare the Join Order Benchmark (JOB / IMDB) dataset as oldest-ClickHouse-
# compatible Native files. Schema (21 tables) is from the ClickHouse repository
# (tests/benchmarks/job/init.sql): `integer` -> Int32, `text`/`varchar` -> String
# (the JOB set has no Decimal and no date columns, so every table carries a
# constant synth_date for the legacy MergeTree engine). NULLs load as type
# defaults (empty CSV field + input_format_csv_empty_as_default).
#
# The source is the canonical IMDB snapshot (Postgres-COPY CSV); job_convert.py
# re-encodes it to standard RFC-4180 CSV that ClickHouse parses.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-$HOME/clickhouse}"
SRC="${JOB_SRC:-https://event.cwi.nl/da/job/imdb.tgz}"
WORK="${HERE}/data/job-work"
command -v "${CLICKHOUSE}" >/dev/null 2>&1 || CLICKHOUSE=clickhouse
mkdir -p "${WORK}"

TABLES="aka_name aka_title cast_info char_name comp_cast_type company_name company_type complete_cast info_type keyword kind_type link_type movie_companies movie_info movie_info_idx movie_keyword movie_link name person_info role_type title"

struct_of() {
    case "$1" in
        aka_name) echo "id Int32, person_id Int32, name String, imdb_index String, name_pcode_cf String, name_pcode_nf String, surname_pcode String, md5sum String" ;;
        aka_title) echo "id Int32, movie_id Int32, title String, imdb_index String, kind_id Int32, production_year Int32, phonetic_code String, episode_of_id Int32, season_nr Int32, episode_nr Int32, note String, md5sum String" ;;
        cast_info) echo "id Int32, person_id Int32, movie_id Int32, person_role_id Int32, note String, nr_order Int32, role_id Int32" ;;
        char_name) echo "id Int32, name String, imdb_index String, imdb_id Int32, name_pcode_nf String, surname_pcode String, md5sum String" ;;
        comp_cast_type) echo "id Int32, kind String" ;;
        company_name) echo "id Int32, name String, country_code String, imdb_id Int32, name_pcode_nf String, name_pcode_sf String, md5sum String" ;;
        company_type) echo "id Int32, kind String" ;;
        complete_cast) echo "id Int32, movie_id Int32, subject_id Int32, status_id Int32" ;;
        info_type) echo "id Int32, info String" ;;
        keyword) echo "id Int32, keyword String, phonetic_code String" ;;
        kind_type) echo "id Int32, kind String" ;;
        link_type) echo "id Int32, link String" ;;
        movie_companies) echo "id Int32, movie_id Int32, company_id Int32, company_type_id Int32, note String" ;;
        movie_info) echo "id Int32, movie_id Int32, info_type_id Int32, info String, note String" ;;
        movie_info_idx) echo "id Int32, movie_id Int32, info_type_id Int32, info String, note String" ;;
        movie_keyword) echo "id Int32, movie_id Int32, keyword_id Int32" ;;
        movie_link) echo "id Int32, movie_id Int32, linked_movie_id Int32, link_type_id Int32" ;;
        name) echo "id Int32, name String, imdb_index String, imdb_id Int32, gender String, name_pcode_cf String, name_pcode_nf String, surname_pcode String, md5sum String" ;;
        person_info) echo "id Int32, person_id Int32, info_type_id Int32, info String, note String" ;;
        role_type) echo "id Int32, role String" ;;
        title) echo "id Int32, title String, imdb_index String, kind_id Int32, production_year Int32, imdb_id Int32, phonetic_code String, episode_of_id Int32, season_nr Int32, episode_nr Int32, series_years String, md5sum String" ;;
    esac
}

if [ ! -f "${WORK}/.extracted" ]; then
    echo "job: downloading ${SRC}"
    curl -fsSL "${SRC}" -o "${WORK}/imdb.tgz"
    echo "job: extracting"
    tar -xzf "${WORK}/imdb.tgz" -C "${WORK}"
    touch "${WORK}/.extracted"
fi

for t in ${TABLES}; do
    csv="$(find "${WORK}" -name "${t}.csv" | head -1)"
    [ -n "${csv}" ] || { echo "job: ${t}.csv not found" >&2; exit 1; }
    python3 "${HERE}/job_convert.py" < "${csv}" \
        | "${CLICKHOUSE}" local --input_format_csv_empty_as_default 1 \
            --input-format CSV --structure "$(struct_of "$t")" \
            --query "SELECT CAST('2000-01-01' AS Date) AS synth_date, * FROM table FORMAT Native" \
        | zstd -q -6 -T0 -c > "${HERE}/data/job_${t}.native.zst"
    echo "  job_${t}.native.zst: $(du -h "${HERE}/data/job_${t}.native.zst" | cut -f1)"
done
rm -rf "${WORK}"
echo "job: done"
