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

# Start the GizmoSQL server. Bounded wait + crash detection: the old code
# spun in `while ! nc -z` forever, so if the spawned server crashed during
# startup (DuckDB lock conflict, missing perms, ...) the bench hung
# permanently — pstree would show ./start stuck on `sleep 1`. Retry the
# spawn a few times if it dies fast (the common case is a stale DuckDB
# fcntl lock from a not-quite-finished sibling thread of the previously
# killed server; sleeping briefly and respawning lets the kernel finish
# releasing the lock).
start_gizmosql() {
    local attempt
    for attempt in 1 2 3 4 5; do
        nohup gizmosql_server \
            --username ${GIZMOSQL_USER} \
            --database-filename clickbench.db \
            --print-queries >> gizmosql_server.log 2>&1 &
        local pid=$!
        echo "$pid" > "${PID_FILE}"
        echo "Waiting for gizmosql_server to start (attempt ${attempt})..."

        local i
        for i in $(seq 1 60); do
            if nc -z ${GIZMOSQL_HOST} ${GIZMOSQL_PORT} 2>/dev/null; then
                echo "gizmosql_server is ready (PID: ${pid})"
                return 0
            fi
            if ! kill -0 "$pid" 2>/dev/null; then
                echo "gizmosql_server (PID: ${pid}) exited before opening port" >&2
                break
            fi
            sleep 1
        done

        # Either dead-on-arrival or didn't bind in 60 s. Clean up before
        # retrying.
        kill "$pid" 2>/dev/null || true
        rm -f "${PID_FILE}"
        sleep 2
    done

    echo "gizmosql_server failed to start after 5 attempts" >&2
    return 1
}

# Stop the GizmoSQL server. The old code did `kill $pid; wait $pid`, but
# `wait` on a non-child returns immediately, so the function exited
# before the process was actually gone. The next start_gizmosql then
# raced the not-fully-released DuckDB fcntl lock and the new server
# crashed with "Could not set lock on file ...: Conflicting lock is held
# in . (PID <old>)" — visible in gizmosql_server.log around the time
# the bench hangs.
stop_gizmosql() {
    if [ -f "${PID_FILE}" ]; then
        local pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping gizmosql_server (PID: ${pid})..."
            kill "$pid"
            # Poll until the process is actually gone (kill -0 fails).
            local i
            for i in $(seq 1 60); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            # Still alive after 60 s — escalate.
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
                sleep 1
            fi
        fi
        rm -f "${PID_FILE}"
    fi
}
