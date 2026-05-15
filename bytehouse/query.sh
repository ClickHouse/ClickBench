#!/usr/bin/env bash

set -euo pipefail

if [[ -x /usr/local/bin/bh-repro && "${BH_REPRO_BYPASS:-0}" != "1" ]]; then
    exec sudo /usr/local/bin/bh-repro query "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

source "${SCRIPT_DIR}/common.sh"

bytehouse::setup_runtime
bytehouse::require_running_server
bytehouse::require_table_loaded

"${SCRIPT_DIR}/run.sh"
