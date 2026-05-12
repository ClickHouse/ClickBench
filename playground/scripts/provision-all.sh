#!/bin/bash
# Kick off /api/admin/provision/<name> for every playground-eligible system.
# The server's own semaphore in VMManager bounds the actual concurrency
# (PLAYGROUND_PROVISION_CONCURRENCY, default 32) — this script just fires
# the requests as fast as the host can accept them, then polls until the
# server reports every system as either snapshotted or down-with-error.

set -euo pipefail

BASE="${PLAYGROUND_BASE:-http://127.0.0.1:8000}"
STATUS_LOG="${STATUS_LOG:-/opt/clickbench-playground/logs/provision-all.status}"
SKIP_PROVISIONED="${SKIP_PROVISIONED:-yes}"

# Fetch the catalog.
mapfile -t SYSTEMS < <(
    curl -fsS "$BASE/api/systems" |
        python3 -c 'import json,sys; [print(x["name"]) for x in json.load(sys.stdin)]'
)

echo "$(date -Is) catalog: ${#SYSTEMS[@]} systems"

# Kick off /provision for each system that isn't already snapshotted.
for sys in "${SYSTEMS[@]}"; do
    if [ "$SKIP_PROVISIONED" = "yes" ]; then
        state=$(curl -fsS "$BASE/api/system/$sys" |
                python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
        if [ "$state" = "snapshotted" ] || [ "$state" = "ready" ]; then
            echo "  $sys: skip (already $state)"
            continue
        fi
    fi
    echo "  $sys: kicking provision"
    curl -fsS -X POST "$BASE/api/admin/provision/$sys" >/dev/null
done

echo "$(date -Is) all kicked off; polling state..."

# Poll until every system reaches a terminal state. Emit one line per
# transition.
declare -A LAST_STATE
while true; do
    in_flight=0
    succeeded=0
    failed=0
    : > "$STATUS_LOG.tmp"
    for sys in "${SYSTEMS[@]}"; do
        body=$(curl -fsS --max-time 5 "$BASE/api/system/$sys" 2>/dev/null || echo '{}')
        state=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state","?"))' 2>/dev/null)
        err=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("last_error") or "")' 2>/dev/null)
        echo "$sys $state $err" >> "$STATUS_LOG.tmp"
        prev="${LAST_STATE[$sys]:-}"
        if [ "$state" != "$prev" ]; then
            ts=$(date -Is)
            echo "$ts $sys: $prev -> $state${err:+ (err=$err)}"
            LAST_STATE[$sys]=$state
        fi
        case "$state" in
            snapshotted|ready) succeeded=$((succeeded+1)) ;;
            down)              [ -n "$err" ] && failed=$((failed+1)) || in_flight=$((in_flight+1)) ;;
            provisioning)      in_flight=$((in_flight+1)) ;;
            *)                 in_flight=$((in_flight+1)) ;;
        esac
    done
    mv "$STATUS_LOG.tmp" "$STATUS_LOG"
    echo "$(date -Is) ok=$succeeded fail=$failed in_flight=$in_flight"
    if [ "$in_flight" -eq 0 ]; then
        echo "$(date -Is) done"
        break
    fi
    sleep 30
done

# Final summary.
echo ""
echo "=== FINAL SUMMARY ==="
awk '{print $2}' "$STATUS_LOG" | sort | uniq -c
echo ""
echo "=== FAILED ==="
awk '$2 == "down" && NF > 2 {print}' "$STATUS_LOG"
