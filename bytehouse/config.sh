#!/usr/bin/env bash

# Benchmark execution
: "${TRIES:=3}"
: "${DROP_CACHES:=1}"
: "${CLEANUP_SERVER_ON_EXIT:=0}"

# Load/import tuning
: "${OPTIMIZE_TABLE_FINAL:=0}"
: "${OPTIMIZE_TABLE_FINAL_SETTINGS:=optimize_throw_if_noop = 0}"
: "${IMPORT_MAX_THREADS:=0}"
: "${IMPORT_MIN_INSERT_BLOCK_SIZE_ROWS:=0}"
: "${IMPORT_MIN_INSERT_BLOCK_SIZE_BYTES:=0}"
: "${IMPORT_MAX_INSERT_BLOCK_SIZE:=0}"
