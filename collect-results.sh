#!/bin/bash

# Writes one JSON per (system, machine) under <system>/results/<YYYYMMDD>/<machine>.json,
# where YYYYMMDD is taken from the recorded UTC time of the result.
clickhouse-client --query "SELECT format(\$\$SELECT output FROM sink.results WHERE system = '{0}' AND machine = '{1}' ORDER BY time DESC LIMIT 1 INTO OUTFILE '{0}/results/{2}/{1}.json' TRUNCATE FORMAT Raw SETTINGS into_outfile_create_parent_directories = 1;\$\$, system, machine, formatDateTime(time, '%Y%m%d', 'UTC')) FROM sink.results WHERE time >= today() - INTERVAL 1 WEEK LIMIT 1 BY system, machine FORMAT Raw" | clickhouse-client
