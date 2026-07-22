#!/bin/bash
# kinetica downloads hits.tsv.gz directly inside ./load (Kinetica wants the
# gzipped form), so no central download script is used.
export BENCH_DOWNLOAD_SCRIPT=""
exec ../lib/benchmark-common.sh
