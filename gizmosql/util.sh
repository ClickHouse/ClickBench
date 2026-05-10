#!/bin/bash

# Variables (env var names match what gizmosql_client recognizes natively)
export GIZMOSQL_HOST=localhost
export GIZMOSQL_PORT=31337
export GIZMOSQL_USER=clickbench
export GIZMOSQL_PASSWORD=clickbench
PID_FILE="/tmp/gizmosql_server_$$.pid"

# Function to start the GizmoSQL server
start_gizmosql() {
    nohup gizmosql_server \
        --username ${GIZMOSQL_USER} \
        --database-filename clickbench.db \
        --storage-version latest \
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
