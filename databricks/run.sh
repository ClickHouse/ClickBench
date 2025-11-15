#!/bin/bash

# Determine the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use venv python if available, otherwise system python
if [ -f "$SCRIPT_DIR/.venv/bin/python3" ]; then
    PYTHON="$SCRIPT_DIR/.venv/bin/python3"
else
    PYTHON="python3"
fi

cat queries.sql | while read -r query; do
    $PYTHON ./query.py <<< "${query}"
done
