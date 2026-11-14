#!/bin/bash
# Spin up the agent in a local sandbox and hit its HTTP endpoints. Useful for
# iterating on agent.py without rebuilding a Firecracker image.
#
# The sandbox is just two temp directories that mimic the in-VM mounts:
#   /tmp/clickbench-selftest/system     — copy of the duckdb system dir
#   /tmp/clickbench-selftest/datasets   — empty
#
# We exercise:
#   GET  /health    expects 200 with provisioned=false
#   GET  /stats     expects 200 with cpu/mem/disk
#   POST /provision expects 200 (will fail unless duckdb is locally installed)
#   POST /query     expects 200 with timing headers, output bytes capped
#
# Cleanup: kills the agent on exit.

set -euo pipefail

SANDBOX="${SANDBOX:-/tmp/clickbench-selftest}"
SYS="${SANDBOX}/system"
DATA="${SANDBOX}/datasets"
PORT="${PORT:-18080}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

rm -rf "$SANDBOX"
mkdir -p "$SYS" "$DATA"
cp -a "$REPO_DIR/duckdb"/. "$SYS"/

# A trivial "system" that doesn't need provisioning: replace install/start/load
# with no-ops so the smoke test focuses on the agent's HTTP path.
cat > "$SYS/install" <<'EOF'
#!/bin/bash
echo "fake install"
EOF
cat > "$SYS/start" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$SYS/check" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$SYS/load" <<'EOF'
#!/bin/bash
echo "fake load"
EOF
# A query script that echoes the request and reports 0.123s.
cat > "$SYS/query" <<'EOF'
#!/bin/bash
cat
echo "0.123" >&2
EOF
chmod +x "$SYS"/{install,start,check,load,query}

echo "selftest: starting agent on :$PORT"
CLICKBENCH_SYSTEM_DIR="$SYS" \
CLICKBENCH_DATASETS_DIR="$DATA" \
CLICKBENCH_AGENT_STATE="$SANDBOX/state" \
CLICKBENCH_SYSTEM_NAME=selftest \
CLICKBENCH_AGENT_PORT="$PORT" \
CLICKBENCH_OUTPUT_LIMIT=64 \
python3 "$REPO_DIR/playground/agent/agent.py" &
AGENT_PID=$!
trap 'kill $AGENT_PID 2>/dev/null || true' EXIT

# wait for listen
for i in {1..30}; do
    if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

echo "--- /health ---"
curl -fsS "http://127.0.0.1:$PORT/health"
echo "--- /stats ---"
curl -fsS "http://127.0.0.1:$PORT/stats"
echo "--- POST /provision ---"
curl -fsS -X POST "http://127.0.0.1:$PORT/provision" | head -c 500; echo

echo "--- POST /query (capped output) ---"
LONG_BODY="$(printf 'X%.0s' {1..2048})"  # 2 KB of X
curl -sS -X POST --data-binary "$LONG_BODY" "http://127.0.0.1:$PORT/query" -D - -o /tmp/clickbench-selftest.out
echo
echo "Output size: $(wc -c < /tmp/clickbench-selftest.out) bytes (cap was 64)"
echo "First chars: $(head -c 32 /tmp/clickbench-selftest.out)"

echo "--- POST /query (without provisioning state) ---"
rm -rf "$SANDBOX/state"
mkdir -p "$SANDBOX/state"
curl -sS -X POST --data-binary "SELECT 1" "http://127.0.0.1:$PORT/query" -D - -o /dev/null | head -3

echo "OK"
