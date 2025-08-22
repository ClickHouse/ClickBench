#!/bin/bash

set -eu

psql -h localhost -p 5432 -U postgres -d test <<'EOF'
\copy hits FROM '/tmp/data/hits.tsv';
EOF

# TODO: see README
#psql -h localhost -p 5432 -U postgres -d test -c 'ANALYZE hits;'
