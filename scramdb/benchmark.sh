#!/bin/bash

export BENCH_DOWNLOAD_SCRIPT="download-hits-csv"

export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-scramdb}"
export PGDATABASE="${PGDATABASE:-scramdb}"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

exec ../lib/benchmark-common.sh
