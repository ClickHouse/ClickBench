#!/bin/bash
export BENCH_DOWNLOAD_SCRIPT="download-hits-tsv"
# The observer's startup is not instant even when nothing has to be replayed:
# it re-reads its schema and tablet metadata, and after ./drop_caches all of
# that comes off the disk. Measured here at 27-45 s warm and a few minutes when
# the volume is busy, against the driver's 300 s default -- and a ./check that
# times out aborts the whole run, so give it room.
export BENCH_CHECK_TIMEOUT=900
exec ../lib/benchmark-common.sh
