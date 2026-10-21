#!/bin/bash
# Sourced by start, stop, load and query.

# The server reads HARDCHARGER_HOST/PORT as its listen address and the
# HARDCHARGER_ADMIN_* pair as its administrator; the client reads the same
# HOST/PORT, HARDCHARGER_ADMIN_USERNAME as its user name, HARDCHARGER_PASSWORD
# and HARDCHARGER_TLS (plain HTTP on the loopback interface).
export HARDCHARGER_HOST=127.0.0.1
export HARDCHARGER_PORT=31337
export HARDCHARGER_ADMIN_USERNAME=clickbench
export HARDCHARGER_ADMIN_PASSWORD=clickbench
export HARDCHARGER_PASSWORD=clickbench
export HARDCHARGER_TLS=false

PID_FILE="${PWD}/hardcharger-server.pid"

hc_ready() {
    curl -fsS -o /dev/null "http://${HARDCHARGER_HOST}:${HARDCHARGER_PORT}/warp"
}

hc_start() {
    hc_ready 2>/dev/null && return 0
    nohup hardcharger-server --database hits.db --storage-version latest \
        >> hardcharger-server.log 2>&1 &
    echo $! > "$PID_FILE"
    for _ in $(seq 1 120); do
        hc_ready 2>/dev/null && return 0
        kill -0 "$(cat "$PID_FILE")" 2>/dev/null || { tail -n 20 hardcharger-server.log >&2; return 1; }
        sleep 0.5
    done
    echo "hardcharger-server did not start" >&2
    return 1
}

# Waits until the process is gone, not just its port: the next start needs
# the database file's lock.
hc_stop() {
    [ -f "$PID_FILE" ] || return 0
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 120); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    kill -KILL "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
}
