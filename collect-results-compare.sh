#!/bin/bash

# Similar to collect-results.sh, but saves new results under different names for comparison.
clickhouse-client --query "SELECT format(\$\$SELECT replaceRegexpOne(output, '\"system\": \"([^\"]+)\"', '\"system\": \"\\1 (new)\"') FROM sink.results WHERE system = '{0}' AND machine = '{1}' ORDER BY time DESC LIMIT 1 INTO OUTFILE '{0}/results/{1}_new.json' TRUNCATE FORMAT Raw;\$\$, system, machine) FROM sink.results WHERE time >= today() - INTERVAL 1 WEEK LIMIT 1 BY system, machine FORMAT Raw" | clickhouse-client
