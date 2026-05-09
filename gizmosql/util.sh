#!/bin/bash

# Variables (env var names match what gizmosql_client recognizes natively)
export GIZMOSQL_HOST=localhost
export GIZMOSQL_PORT=31337
export GIZMOSQL_USER=clickbench
export GIZMOSQL_PASSWORD=clickbench
# Fixed PID-file path so start/stop/load/query all resolve to the same file
# even though each one sources util.sh in its own subshell.
PID_FILE="${PWD}/gizmosql_server.pid"

# Wait for the server to become reachable. Used by stop after kill, and by
# load before reusing the database.
wait_for_gizmosql() {
    while ! nc -z "${GIZMOSQL_HOST}" "${GIZMOSQL_PORT}" 2>/dev/null; do
        sleep 1
    done
}

# Function to start the GizmoSQL server
start_gizmosql() {
    nohup gizmosql_server \
        --username ${GIZMOSQL_USER} \
        --database-filename clickbench.db \
        --print-queries >> gizmosql_server.log 2>&1 &

    echo $! > "${PID_FILE}"

    # Wait for server to be ready
    echo "Waiting for gizmosql_server to start..."
    while ! nc -z ${GIZMOSQL_HOST} ${GIZMOSQL_PORT} 2>/dev/null; do
        sleep 1
    done
    echo "gizmosql_server is ready (PID: $(cat ${PID_FILE}))"
}

# Function to stop the GizmoSQL server
stop_gizmosql() {
    if [ -f "${PID_FILE}" ]; then
        local pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping gizmosql_server (PID: $pid)..."
            kill "$pid"
            wait "$pid" 2>/dev/null
        fi
        rm -f "${PID_FILE}"
    fi
}
