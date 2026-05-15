#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source "${SCRIPT_DIR}/common.sh"

bytehouse::setup_runtime

: > "${RESULT_CSV}"
: > "${RESULT_MATRIX_CSV}"

declare -a attempt_sums=()
declare -a attempt_sum_invalid=()

for attempt in $(seq 1 "${TRIES}"); do
    attempt_sums[${attempt}]=0
    attempt_sum_invalid[${attempt}]=0
done

query_num=1
while IFS= read -r query || [[ -n "${query}" ]]; do
    [[ -z "${query}" ]] && continue

    declare -a row_results=()

    bytehouse::maybe_drop_caches

    echo -n "["
    for attempt in $(seq 1 "${TRIES}"); do
        if result="$(bytehouse::run_query "${query}")"; then
            row_results[${attempt}]="${result}"
            echo -n "${result}"
            echo "${query_num},${attempt},${result}" >> "${RESULT_CSV}"
            if [[ "${attempt_sum_invalid[${attempt}]}" == "0" ]]; then
                attempt_sums[${attempt}]="$(awk -v a="${attempt_sums[${attempt}]}" -v b="${result}" 'BEGIN { print a + b }')"
            fi
        else
            row_results[${attempt}]="null"
            echo -n "null"
            echo "${query_num},${attempt},null" >> "${RESULT_CSV}"
            attempt_sum_invalid[${attempt}]=1
            [[ -n "${result}" ]] && echo "Query ${query_num} attempt ${attempt} failed: ${result}" >&2
        fi

        if [[ "${attempt}" != "${TRIES}" ]]; then
            echo -n ", "
        fi
    done
    echo "],"
    printf '%s\n' "$(IFS=,; echo "${row_results[*]}")" >> "${RESULT_MATRIX_CSV}"

    query_num=$((query_num + 1))
done < "${QUERY_FILE}"

declare -a sum_results=()
for attempt in $(seq 1 "${TRIES}"); do
    if [[ "${attempt_sum_invalid[${attempt}]}" == "1" ]]; then
        sum_results[${attempt}]="null"
    else
        sum_results[${attempt}]="${attempt_sums[${attempt}]}"
    fi
done
printf '%s\n' "$(IFS=,; echo "${sum_results[*]}")" >> "${RESULT_MATRIX_CSV}"
