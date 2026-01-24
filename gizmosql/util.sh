#!/bin/bash

# Variables
GIZMOSQL_SERVER_URI="jdbc:arrow-flight-sql://localhost:31337?useEncryption=false"
GIZMOSQL_USERNAME=clickbench
GIZMOSQL_PASSWORD=clickbench
PID_FILE="/tmp/gizmosql_server_$$.pid"

# Function to start the GizmoSQL server
start_gizmosql() {
    export GIZMOSQL_PASSWORD="${GIZMOSQL_PASSWORD}"

    nohup gizmosql_server \
        --username ${GIZMOSQL_USERNAME} \
        --database-filename clickbench.db \
        --print-queries >> gizmosql_server.log 2>&1 &

    echo $! > "${PID_FILE}"

    # Wait for server to be ready
    echo "Waiting for gizmosql_server to start..."
    while ! nc -z localhost 31337 2>/dev/null; do
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
