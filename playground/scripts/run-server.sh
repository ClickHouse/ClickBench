#!/bin/bash
# Convenience wrapper to start the playground API server in the foreground.
# Looks for .env in the repo root for ClickHouse Cloud creds.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -f "$REPO_DIR/playground/.env" ]; then
    # shellcheck disable=SC2046
    export $(grep -v '^#' "$REPO_DIR/playground/.env" | xargs)
fi

cd "$REPO_DIR"
exec python3 -m playground.server.main
