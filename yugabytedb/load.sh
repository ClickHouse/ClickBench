#!/bin/bash

set -eux

time ./yugabyte/bin/ysqlsh -U yugabyte -d test <<'EOF'
\copy hits FROM 'hits.tsv';
EOF

time ./yugabyte/bin/ysqlsh -U yugabyte -d test -t -c 'ANALYZE hits;'
