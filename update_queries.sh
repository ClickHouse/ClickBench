#!/bin/bash

PASSWORD=${PASSWORD:-}
clickhouse client --host z0ur79yngg.us-central1.gcp.clickhouse-staging.com --password "$PASSWORD" --secure --query "SELECT formatQuerySingleLine(query) FROM queries ORDER BY number ASC FORMAT LineAsString" > queries.new.sql
