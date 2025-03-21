#!/bin/bash

set -eux

export PGUSER=postgres
export PGPASSWORD=duckdb

# Load data: wrap TRUNCATE and \copy FREEZE in a single transaction
# If we dont' do this, Postgres will throw an error:
#     "ERROR: cannot perform COPY FREEZE because the table was not created or truncated in the current subtransaction"
# (i.e. Postgres requires that the table be either created or truncated in the current subtransaction)
time psql <<'EOF'
BEGIN;
TRUNCATE TABLE hits;
\copy hits FROM 'hits.tsv' with freeze;
COMMIT;
EOF

time psql -t -c 'VACUUM ANALYZE hits'
