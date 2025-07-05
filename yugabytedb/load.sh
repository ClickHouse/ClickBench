#!/bin/bash

set -eux

./yugabyte/bin/ysqlsh -U yugabyte -d test <<'EOF'
\copy hits FROM 'hits.tsv';
EOF

./yugabyte/bin/ysqlsh -U yugabyte -d test -t -c 'ANALYZE hits;'
