#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="${SCRIPT_DIR}/bundle"
if [[ ! -d "${BUNDLE_DIR}" ]]; then
    BUNDLE_DIR="/opt/bytehouse"
fi
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.sh}"
SERVER_CONFIG_TEMPLATE="${SERVER_CONFIG_TEMPLATE:-${SCRIPT_DIR}/config.xml}"
SERVER_USERS_TEMPLATE="${SERVER_USERS_TEMPLATE:-${SCRIPT_DIR}/users.xml}"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Missing ByteHouse benchmark config: ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

CLICKHOUSE_BIN="${CLICKHOUSE_BIN:-${BUNDLE_DIR}/bin/bytehouse}"
CLICKHOUSE_LIB_DIR="${CLICKHOUSE_LIB_DIR:-${BUNDLE_DIR}/lib}"

QUERY_FILE="${QUERY_FILE:-${SCRIPT_DIR}/queries.sql}"
CREATE_SQL_FILE="${CREATE_SQL_FILE:-${SCRIPT_DIR}/create.sql}"
DATA_FILE="${DATA_FILE:-${SCRIPT_DIR}/hits.parquet}"
RESULT_CSV="${RESULT_CSV:-${SCRIPT_DIR}/result.csv}"
RESULT_MATRIX_CSV="${RESULT_MATRIX_CSV:-${SCRIPT_DIR}/result_matrix.csv}"

TABLE_NAME="${TABLE_NAME:-hits}"
LOCAL_TABLE_NAME="${LOCAL_TABLE_NAME:-hits_local}"
CLUSTER_NAME="${CLUSTER_NAME:-bytehouse_single}"
DATA_FORMAT="${DATA_FORMAT:-Parquet}"
HITS_DATA_URL="${HITS_DATA_URL:-https://datasets.clickhouse.com/hits_compatible/hits.parquet}"

SERVER_HOST="${SERVER_HOST:-127.0.0.1}"
SERVER_PORT="${SERVER_PORT:-19000}"
SERVER_HTTP_PORT="${SERVER_HTTP_PORT:-18123}"
SERVER_MYSQL_PORT="${SERVER_MYSQL_PORT:-19004}"
SERVER_HA_TCP_PORT="${SERVER_HA_TCP_PORT:-19019}"
SERVER_EXCHANGE_PORT="${SERVER_EXCHANGE_PORT:-19001}"
SERVER_EXCHANGE_STATUS_PORT="${SERVER_EXCHANGE_STATUS_PORT:-19002}"
SERVER_INTERSERVER_HTTP_PORT="${SERVER_INTERSERVER_HTTP_PORT:-18124}"
SERVER_KEEPER_TCP_PORT="${SERVER_KEEPER_TCP_PORT:-19181}"
SERVER_KEEPER_RAFT_PORT="${SERVER_KEEPER_RAFT_PORT:-19234}"
RUNTIME_DIR="${RUNTIME_DIR:-${SCRIPT_DIR}/.runtime}"
SERVER_DATA_DIR="${SERVER_DATA_DIR:-${RUNTIME_DIR}/data}"
SERVER_TMP_DIR="${SERVER_TMP_DIR:-${RUNTIME_DIR}/tmp}"
SERVER_USER_FILES_DIR="${SERVER_USER_FILES_DIR:-${RUNTIME_DIR}/user_files}"
SERVER_LOG_DIR="${SERVER_LOG_DIR:-${RUNTIME_DIR}/logs}"
SERVER_FORMAT_SCHEMA_DIR="${SERVER_FORMAT_SCHEMA_DIR:-${RUNTIME_DIR}/format_schemas}"
SERVER_KEEPER_LOG_DIR="${SERVER_KEEPER_LOG_DIR:-${RUNTIME_DIR}/keeper/log}"
SERVER_KEEPER_SNAPSHOT_DIR="${SERVER_KEEPER_SNAPSHOT_DIR:-${RUNTIME_DIR}/keeper/snapshot}"
SERVER_CONFIG_FILE="${SERVER_CONFIG_FILE:-${RUNTIME_DIR}/config.xml}"
SERVER_USERS_FILE="${SERVER_USERS_FILE:-${RUNTIME_DIR}/users.xml}"
SERVER_PID_FILE="${SERVER_PID_FILE:-${RUNTIME_DIR}/server.pid}"
SERVER_LOG_FILE="${SERVER_LOG_FILE:-${SERVER_LOG_DIR}/server.log}"
SERVER_ERROR_LOG_FILE="${SERVER_ERROR_LOG_FILE:-${SERVER_LOG_DIR}/server.err.log}"

QUERY_CLIENT_FLAGS="${QUERY_CLIENT_FLAGS:-}"
declare -a QUERY_CLIENT_FLAG_ARGS=()
if [[ -n "${QUERY_CLIENT_FLAGS}" ]]; then
    read -r -a QUERY_CLIENT_FLAG_ARGS <<< "${QUERY_CLIENT_FLAGS}"
fi

export LD_LIBRARY_PATH="${CLICKHOUSE_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

bytehouse::require_file() {
    local path="$1"
    local description="$2"

    if [[ ! -f "${path}" ]]; then
        echo "Missing ${description}: ${path}" >&2
        exit 1
    fi
}

bytehouse::setup_runtime() {
    bytehouse::require_file "${CLICKHOUSE_BIN}" "ByteHouse binary"
    bytehouse::require_file "${QUERY_FILE}" "ClickBench query file"
    bytehouse::require_file "${CREATE_SQL_FILE}" "ClickBench create.sql"
    bytehouse::require_file "${SERVER_CONFIG_TEMPLATE}" "ByteHouse config.xml template"
    bytehouse::require_file "${SERVER_USERS_TEMPLATE}" "ByteHouse users.xml template"
}

bytehouse::download_data_if_needed() {
    if [[ "${FORCE_REDOWNLOAD_DATA:-0}" == "1" ]]; then
        rm -f "${DATA_FILE}"
    fi

    if [[ -f "${DATA_FILE}" ]]; then
        return 0
    fi

    echo "Downloading dataset to ${DATA_FILE} ..." >&2
    if command -v wget >/dev/null 2>&1; then
        wget --continue --progress=dot:giga -O "${DATA_FILE}" "${HITS_DATA_URL}"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --fail --output "${DATA_FILE}" "${HITS_DATA_URL}"
    else
        echo "Neither wget nor curl is available for downloading ${HITS_DATA_URL}" >&2
        exit 1
    fi
}

bytehouse::prepare_server_runtime() {
    rm -rf "${SERVER_DATA_DIR}" "${SERVER_TMP_DIR}" "${SERVER_USER_FILES_DIR}" "${SERVER_LOG_DIR}" "${SERVER_FORMAT_SCHEMA_DIR}" "${SERVER_KEEPER_LOG_DIR}" "${SERVER_KEEPER_SNAPSHOT_DIR}"
    mkdir -p \
        "${SERVER_DATA_DIR}" \
        "${SERVER_TMP_DIR}" \
        "${SERVER_USER_FILES_DIR}" \
        "${SERVER_LOG_DIR}" \
        "${SERVER_FORMAT_SCHEMA_DIR}" \
        "${SERVER_KEEPER_LOG_DIR}" \
        "${SERVER_KEEPER_SNAPSHOT_DIR}"

    rm -f "${SERVER_CONFIG_FILE}" "${SERVER_USERS_FILE}" "${SERVER_PID_FILE}"
}

bytehouse::stage_data_file() {
    bytehouse::require_file "${DATA_FILE}" "ClickBench data file"
    cp -f "${DATA_FILE}" "${SERVER_USER_FILES_DIR}/$(basename "${DATA_FILE}")"
}

bytehouse::write_server_config() {
    local config_content
    local users_content

    config_content="$(<"${SERVER_CONFIG_TEMPLATE}")"
    config_content="${config_content//__SERVER_LOG_FILE__/${SERVER_LOG_FILE}}"
    config_content="${config_content//__SERVER_ERROR_LOG_FILE__/${SERVER_ERROR_LOG_FILE}}"
    config_content="${config_content//__SERVER_HOST__/${SERVER_HOST}}"
    config_content="${config_content//__SERVER_HTTP_PORT__/${SERVER_HTTP_PORT}}"
    config_content="${config_content//__SERVER_PORT__/${SERVER_PORT}}"
    config_content="${config_content//__SERVER_MYSQL_PORT__/${SERVER_MYSQL_PORT}}"
    config_content="${config_content//__SERVER_HA_TCP_PORT__/${SERVER_HA_TCP_PORT}}"
    config_content="${config_content//__SERVER_EXCHANGE_STATUS_PORT__/${SERVER_EXCHANGE_STATUS_PORT}}"
    config_content="${config_content//__SERVER_EXCHANGE_PORT__/${SERVER_EXCHANGE_PORT}}"
    config_content="${config_content//__SERVER_INTERSERVER_HTTP_PORT__/${SERVER_INTERSERVER_HTTP_PORT}}"
    config_content="${config_content//__SERVER_DATA_DIR__/${SERVER_DATA_DIR}}"
    config_content="${config_content//__SERVER_TMP_DIR__/${SERVER_TMP_DIR}}"
    config_content="${config_content//__SERVER_USER_FILES_DIR__/${SERVER_USER_FILES_DIR}}"
    config_content="${config_content//__SERVER_FORMAT_SCHEMA_DIR__/${SERVER_FORMAT_SCHEMA_DIR}}"
    config_content="${config_content//__CLUSTER_NAME__/${CLUSTER_NAME}}"
    config_content="${config_content//__SERVER_KEEPER_TCP_PORT__/${SERVER_KEEPER_TCP_PORT}}"
    config_content="${config_content//__SERVER_KEEPER_LOG_DIR__/${SERVER_KEEPER_LOG_DIR}}"
    config_content="${config_content//__SERVER_KEEPER_SNAPSHOT_DIR__/${SERVER_KEEPER_SNAPSHOT_DIR}}"
    config_content="${config_content//__SERVER_KEEPER_RAFT_PORT__/${SERVER_KEEPER_RAFT_PORT}}"
    config_content="${config_content//__SERVER_USERS_FILE__/${SERVER_USERS_FILE}}"

    printf '%s\n' "${config_content}" > "${SERVER_CONFIG_FILE}"

    users_content="$(<"${SERVER_USERS_TEMPLATE}")"
    printf '%s\n' "${users_content}" > "${SERVER_USERS_FILE}"
}

bytehouse::server_is_running() {
    if [[ ! -f "${SERVER_PID_FILE}" ]]; then
        return 1
    fi

    local pid
    pid="$(cat "${SERVER_PID_FILE}")"
    if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi

    if ! bytehouse::client --query "SELECT 1" >/dev/null 2>&1; then
        return 1
    fi

    bytehouse::verify_server_identity >/dev/null 2>&1
}

bytehouse::require_running_server() {
    if ! bytehouse::server_is_running; then
        echo "ByteHouse server is not running. Start it with ./benchmark.sh first, or keep CLEANUP_SERVER_ON_EXIT=0 for query-only reruns." >&2
        exit 1
    fi
}

bytehouse::require_table_loaded() {
    local exists

    exists="$(bytehouse::client --query "EXISTS TABLE ${LOCAL_TABLE_NAME} FORMAT TSVRaw" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${exists}" != "1" ]]; then
        echo "Table ${LOCAL_TABLE_NAME} does not exist. Run ./benchmark.sh to create and load data first." >&2
        exit 1
    fi
}

bytehouse::client() {
    "${CLICKHOUSE_BIN}" client \
        --host "${SERVER_HOST}" \
        --port "${SERVER_PORT}" \
        "$@"
}

bytehouse::verify_server_identity() {
    local actual_user_files_path
    local actual_tcp_port

    actual_user_files_path="$(bytehouse::client --query "SELECT value FROM system.server_settings WHERE name = 'user_files_path' FORMAT TSVRaw" 2>/dev/null | tr -d '\r')"
    actual_tcp_port="$(bytehouse::client --query "SELECT value FROM system.server_settings WHERE name = 'tcp_port' FORMAT TSVRaw" 2>/dev/null | tr -d '\r')"

    if [[ -n "${actual_tcp_port}" && "${actual_tcp_port}" != "${SERVER_PORT}" ]]; then
        echo "Connected to unexpected ClickHouse TCP port: ${actual_tcp_port} (expected ${SERVER_PORT})." >&2
        echo "This usually means another local ClickHouse service is running and the benchmark is connected to the wrong instance." >&2
        exit 1
    fi

    if [[ -n "${actual_user_files_path}" && "${actual_user_files_path}" != "${SERVER_USER_FILES_DIR}/" ]]; then
        echo "Connected server user_files_path is ${actual_user_files_path}, expected ${SERVER_USER_FILES_DIR}/." >&2
        echo "This usually means the benchmark is connected to another ClickHouse service instead of the Ce ByteHouse instance started by the script." >&2
        exit 1
    fi
}

bytehouse::wait_for_server() {
    local attempt

    for attempt in $(seq 1 60); do
        if bytehouse::client --query "SELECT 1" >/dev/null 2>&1; then
            bytehouse::verify_server_identity
            return 0
        fi
        sleep 1
    done

    echo "ByteHouse server did not become ready in time." >&2
    if [[ -f "${SERVER_LOG_FILE}" ]]; then
        echo "--- server log ---" >&2
        tail -n 50 "${SERVER_LOG_FILE}" >&2 || true
    fi
    if [[ -f "${SERVER_ERROR_LOG_FILE}" ]]; then
        echo "--- server error log ---" >&2
        tail -n 50 "${SERVER_ERROR_LOG_FILE}" >&2 || true
    fi
    exit 1
}

bytehouse::start_server() {
    bytehouse::stop_server
    bytehouse::prepare_server_runtime
    bytehouse::stage_data_file
    bytehouse::write_server_config

    "${CLICKHOUSE_BIN}" server \
        --config-file "${SERVER_CONFIG_FILE}" \
        --daemon \
        --pidfile "${SERVER_PID_FILE}"

    bytehouse::wait_for_server
}

bytehouse::stop_server() {
    if [[ -f "${SERVER_PID_FILE}" ]]; then
        local pid
        local attempt
        pid="$(cat "${SERVER_PID_FILE}")"
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            for attempt in $(seq 1 30); do
                if ! kill -0 "${pid}" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
        rm -f "${SERVER_PID_FILE}"
    fi
}

bytehouse::create_table() {
    bytehouse::client --multiquery < "${CREATE_SQL_FILE}"
}

bytehouse::import_data() {
    local data_name
    local insert_threads
    local -a insert_settings=()
    local -a client_args=()

    data_name="$(basename "${DATA_FILE}")"

    if [[ -n "${IMPORT_MAX_THREADS}" && "${IMPORT_MAX_THREADS}" == "0" ]]; then
        insert_threads=$(( $(nproc) / 4 ))
        (( insert_threads < 1 )) && insert_threads=1
        insert_settings+=("max_insert_threads = ${insert_threads}")
        client_args+=(--max_insert_threads "${insert_threads}")
    elif [[ -n "${IMPORT_MAX_THREADS}" ]]; then
        insert_threads="${IMPORT_MAX_THREADS}"
        insert_settings+=("max_insert_threads = ${insert_threads}")
        client_args+=(--max_insert_threads "${insert_threads}")
    fi

    if [[ -n "${IMPORT_MIN_INSERT_BLOCK_SIZE_ROWS}" && "${IMPORT_MIN_INSERT_BLOCK_SIZE_ROWS}" != "0" ]]; then
        insert_settings+=("min_insert_block_size_rows = ${IMPORT_MIN_INSERT_BLOCK_SIZE_ROWS}")
    fi

    if [[ -n "${IMPORT_MIN_INSERT_BLOCK_SIZE_BYTES}" && "${IMPORT_MIN_INSERT_BLOCK_SIZE_BYTES}" != "0" ]]; then
        insert_settings+=("min_insert_block_size_bytes = ${IMPORT_MIN_INSERT_BLOCK_SIZE_BYTES}")
    fi

    if [[ -n "${IMPORT_MAX_INSERT_BLOCK_SIZE}" && "${IMPORT_MAX_INSERT_BLOCK_SIZE}" != "0" ]]; then
        insert_settings+=("max_insert_block_size = ${IMPORT_MAX_INSERT_BLOCK_SIZE}")
    fi

    bytehouse::client \
        --query "INSERT INTO ${LOCAL_TABLE_NAME} SELECT * FROM file('${data_name}', ${DATA_FORMAT})$(if ((${#insert_settings[@]} > 0)); then printf ' SETTINGS %s' "$(IFS=', '; echo "${insert_settings[*]}")"; fi)" \
        "${client_args[@]}" 2>&1 | tail -n1
}

bytehouse::optimize_table_final() {
    if [[ "${OPTIMIZE_TABLE_FINAL}" != "1" ]]; then
        return 0
    fi

    bytehouse::client \
        --query "OPTIMIZE TABLE ${LOCAL_TABLE_NAME} FINAL SETTINGS ${OPTIMIZE_TABLE_FINAL_SETTINGS}" >/dev/null
}

bytehouse::load_data() {
    {
        TIMEFORMAT='%R'
        time {
            bytehouse::import_data >/dev/null
            bytehouse::optimize_table_final
        }
    } 2>&1 | tail -n1
}

bytehouse::table_size_bytes() {
    bytehouse::client \
        --query "SELECT total_bytes FROM system.tables WHERE database = currentDatabase() AND name = '${LOCAL_TABLE_NAME}'" 2>/dev/null | tr -d '[:space:]'
}

bytehouse::maybe_drop_caches() {
    [[ "${DROP_CACHES}" != "1" ]] && return 0

    if sudo -n /usr/local/sbin/drop-caches.sh 2>/dev/null; then
        return 0
    fi
    echo "DROP_CACHES=1 requested, but dropping caches is not permitted; continuing without it." >&2
}

bytehouse::run_query() {
    local query="$1"

    bytehouse::client \
        --time \
        --format Null \
        "${QUERY_CLIENT_FLAG_ARGS[@]}" \
        --query "${query}" 2>&1 | tail -n1
}
