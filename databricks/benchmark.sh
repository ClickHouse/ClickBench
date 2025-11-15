#!/bin/bash

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
