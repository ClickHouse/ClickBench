#!/bin/bash
# Run arbitrary (non-ClickBench) SQL through ZigHouse's generic execution path.
#
# ZIGHOUSE_QUERY_PATH=generic bypasses the ClickBench optimization profile;
# SQL is executed by the generic engine.  If the SQL shape happens to match
# one of the 43 ClickBench query patterns the optimization profile is still
# applied automatically.
#
# Run from this directory after benchmark.sh has imported the dataset:
#
#   ./generic-smoke.sh
#
set -u

STORE=${STORE:-/var/lib/zighouse/hits}
ZH=${ZIGHOUSE:-./zighouse}

run() {
  echo "== $1  [$2] =="
  echo "SQL: $3"
  ZIGHOUSE_QUERY_PATH=generic "$ZH" query "$STORE" "$3" || echo "  -> error"
  echo
}

# Supported: scalar aggregates, COUNT(DISTINCT), GROUP BY on low-cardinality
# columns, WHERE with numeric and date conditions combined by AND.
run "count_all"         supported "SELECT COUNT(*) FROM hits"
run "sum_with_filter"   supported "SELECT SUM(Age) FROM hits WHERE EventDate >= '2013-07-15'"
run "min_max_date"      supported "SELECT MIN(EventDate), MAX(EventDate) FROM hits"
run "count_distinct"    supported "SELECT COUNT(DISTINCT CounterID) FROM hits"
run "groupby_counter"   supported "SELECT CounterID, COUNT(*) FROM hits GROUP BY CounterID"
run "where_and"         likely    "SELECT COUNT(*) FROM hits WHERE Age > 25 AND EventDate >= '2013-07-10'"
run "groupby_topk"      likely    "SELECT CounterID, COUNT(*) AS c FROM hits GROUP BY CounterID ORDER BY c DESC LIMIT 10"

# Roadmap: GROUP BY on high-cardinality string columns, arbitrary table import.
run "groupby_url_topk"  roadmap   "SELECT URL, COUNT(*) FROM hits GROUP BY URL ORDER BY COUNT(*) DESC LIMIT 10"
