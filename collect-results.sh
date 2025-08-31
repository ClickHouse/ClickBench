#!/bin/bash

clickhouse-client --query "SELECT format(\$\$SELECT output FROM sink.results WHERE system = '{0}' AND machine = '{1}' ORDER BY time DESC LIMIT 1 INTO OUTFILE '{0}/results/{1}.json' TRUNCATE FORMAT Raw;\$\$, system, machine) FROM sink.results LIMIT 1 BY system, machine FORMAT Raw" | clickhouse-client
