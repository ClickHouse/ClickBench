#!/bin/bash

pushd "$(dirname "${BASH_SOURCE[0]}")/.."
for BENCHMARK in clickhouse clickhouse-datalake clickhouse-parquet clickhouse-web
do
    pushd "${BENCHMARK}"
    ./update-from-play.sql
    popd
done
popd
