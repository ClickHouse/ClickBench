#!/bin/bash

#import
psql "$CONNECTION_STRING" < create.sql
psql "$CONNECTION_STRING" -c "SELECT create_hypertable('hits', 'eventtime', chunk_time_interval => interval '3 day', create_default_indexes => false)" 
psql "$CONNECTION_STRING" -c "ALTER TABLE hits SET (timescaledb.compress, timescaledb.compress_segmentby = '', timescaledb.compress_orderby = 'counterid, userid', 'eventtime')"
psql "$CONNECTION_STRING" -c "ALTER DATABASE tsdb set min_parallel_table_scan_size to 0;"
psql "$CONNECTION_STRING" -c "ALTER DATABASE tsdb set work_mem to '1GB';"
psql "$CONNECTION_STRING" -c "ALTER DATABASE tsdb SET timescaledb.enable_chunk_skipping to ON;"
psql "$CONNECTION_STRING" -c "SELECT enable_chunk_skipping('hits', 'counterid');"

psql "$CONNECTION_STRING" -t -c '\timing' -c "\\copy hits FROM 'hits.tsv'" 
psql "$CONNECTION_STRING" -c "SELECT compress_chunk(i, if_not_compressed => true) FROM show_chunks('hits') i" 
psql "$CONNECTION_STRING" -t -c '\timing' -c "vacuum freeze analyze hits;" 
