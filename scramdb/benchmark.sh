#!/bin/bash

export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-scramdb}"
export PGDATABASE="${PGDATABASE:-scramdb}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export SCRAMDB_IMAGE="${SCRAMDB_IMAGE:-scramdb/scramdb:latest}"

exec ../lib/benchmark-common.sh
