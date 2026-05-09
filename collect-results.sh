#!/bin/bash

# Writes one JSON per (system, machine) under <system>/results/<YYYYMMDD>/<machine>.json,
# where YYYYMMDD is taken from the recorded UTC time of the result.
#
# `LIMIT 1 BY system, machine` without an explicit `ORDER BY` returned an
# arbitrary row per (system, machine) — for systems with several runs in
# the past week, that picked an older row's date for the output directory
# while the inner `ORDER BY time DESC LIMIT 1` still wrote the latest
# content. The result was JSON files landing in the wrong dated subdir
# and `generate-results.sh` never seeing today's entries. Order
# explicitly so LIMIT 1 BY keeps the latest row for each pair.
clickhouse-client --query "SELECT format(\$\$SELECT output FROM sink.results WHERE system = '{0}' AND machine = '{1}' ORDER BY time DESC LIMIT 1 INTO OUTFILE '{0}/results/{2}/{1}.json' TRUNCATE FORMAT Raw SETTINGS into_outfile_create_parent_directories = 1;\$\$, system, machine, formatDateTime(time, '%Y%m%d', 'UTC')) FROM sink.results WHERE time >= today() - INTERVAL 1 WEEK ORDER BY time DESC LIMIT 1 BY system, machine FORMAT Raw" | clickhouse-client
