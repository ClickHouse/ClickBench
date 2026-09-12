#!/bin/bash

# Hyper reads the database directly from S3. No local dataset download runs.
export BENCH_DOWNLOAD_SCRIPT=""

exec ../lib/benchmark-common.sh
