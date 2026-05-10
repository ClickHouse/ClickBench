#!/bin/bash
# Thin shim — actual flow is in lib/benchmark-common.sh.
# kinetica downloads hits.tsv.gz directly inside ./load (Kinetica wants the
# gzipped form), so no central download script is used.
export BENCH_DOWNLOAD_SCRIPT=""
export BENCH_DURABLE=yes
exec ../lib/benchmark-common.sh
