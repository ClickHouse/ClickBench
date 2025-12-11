#!/bin/bash

# Ensure uv is installed, using snap on Linux and the official installer on macOS
if ! command -v uv >/dev/null 2>&1; then
    if command -v snap >/dev/null 2>&1; then
        sudo snap install --classic astral-uv
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
    else
        echo "Error: uv is not installed and snap is unavailable. Please install uv manually." >&2
        exit 1
    fi
fi

# Load environment variables
if [ -f .env ]; then
    set -a
    source .env
    set +a
else
    echo "Error: .env file not found. Please copy .env.example to .env and fill in your credentials."
    exit 1
fi

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    uv venv
fi

# Install dependencies
uv pip install databricks-sql-connector

# Run benchmark
uv run python ./benchmark.py 2>&1
