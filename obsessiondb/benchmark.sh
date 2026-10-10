#!/bin/bash -e

# Go to https://console.obsessiondb.com/ and claim a free dev instance.
# To reproduce the sized results in results/, write to marc@obsessiondb.com and we will
# grant you $500 of credits so you can run the benchmark on the same instance sizes.
# The number of threads is "SELECT value FROM system.settings WHERE name = 'max_threads'".

# Load the data

# export FQDN=...
# export PASSWORD=...

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure < create.sql

MAX_INSERT_THREADS=$(clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT intDiv(getSetting('max_threads'), 4)")

# The source is spelled `urlCluster('cluster', ...)` on purpose. With parallel replicas enabled,
# `parallel_distributed_insert_select = 2` (the default) forwards this INSERT SELECT to every replica
# and hands the 100 files out through a task iterator, so each replica loads only its share.
# Since ClickHouse 26.6 a plain `url(...)` is auto-converted to the cluster storage on the initiator,
# but the forwarded query still says `url(...)`, and a plain `url(...)` on a replica ignores the task
# iterator and reads all 100 files — every replica inserts the full dataset, and a service with N
# replicas ends up with N copies of the data (the load time and query times grow accordingly).
clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --time --enable-parallel-replicas 1 --max-insert-threads $MAX_INSERT_THREADS --query "
  INSERT INTO hits SELECT * FROM urlCluster('cluster', 'https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet')
"

# Refuse to report results for a table that does not contain exactly the dataset.
# A non-numeric last line makes collect-results.sh skip this run instead of publishing it.
EXPECTED_ROWS=99997497
ROWS=$(clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT count() FROM hits")
if [ "$ROWS" != "$EXPECTED_ROWS" ]
then
    echo "Error: the table contains $ROWS rows, expected $EXPECTED_ROWS. Not running the queries." >&2
    exit 1
fi

# Run the queries

./run.sh

clickhouse-client --host "$FQDN" --password "$PASSWORD" --secure --query "SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"
