#!/bin/bash

set -eu

psql -h localhost -p 5432 -U postgres -d test <<'EOF'
\copy hits FROM '/tmp/data/hits.tsv';
EOF

# Updating statistics (`ANALYZE`) currently returns with the following error.
#     ERROR:  unexpected NULL detoast result
# The issue was reported upstream as https://github.com/orioledb/orioledb/issues/535
#
# psql -h localhost -p 5432 -U postgres -d test -c 'ANALYZE hits;'
