#!/usr/bin/env bash

# Set shell options to ensure script execution is safe and predictable
set -euo pipefail

# Enable debug mode
set -x

# Set environment variable defaults
export AXIOM_URL="${AXIOM_URL:-https://axiom.co}"
export AXIOM_DATASET="${AXIOM_DATASET:-axiom-clickbench}"

# Ensure AXIOM_ORG_ID is set
if [ -z "${AXIOM_ORG_ID:-}" ]; then
  echo "AXIOM_ORG_ID environment variable must be set" >&2
  exit 1
fi

# Ensure AXIOM_TOKEN is set
if [ -z "${AXIOM_TOKEN:-}" ]; then
  echo "AXIOM_TOKEN environment variable must be set" >&2
  exit 1
fi

# Download hits.json.gz file if not already present
if [ ! -f hits.json.gz ]; then
  wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.json.gz'
fi

# Ingest the hits.json.gz file into the Axiom dataset
axiom ingest "$AXIOM_DATASET" \
  --auth-org-id "$AXIOM_ORG_ID" \
  --auth-token "$AXIOM_TOKEN" \
  --content-type json \
  --content-encoding gzip \
  --timestamp-field EventTime \
  < hits.json.gz
