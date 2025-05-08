#!/bin/bash

PASSWORD=${CLICKHOUSE_PASSWORD:-}
clickhouse client --host "${CLICKHOUSE_HOST}" --password "${CLICKHOUSE_PASSWORD}" --user ${CLICKHOUSE_USER:=demobench} --secure --query "SELECT formatQuerySingleLine(query) FROM queries ORDER BY number ASC FORMAT LineAsString" > queries.new.sql
