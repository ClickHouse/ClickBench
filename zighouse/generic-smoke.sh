#!/bin/bash
# Run arbitrary (non-ClickBench) SQL through ZigHouse's generic execution path.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STORE=${ZIGHOUSE_STORE:-"${SCRIPT_DIR}/zighouse-store"}
ZH=${ZIGHOUSE:-./zighouse}

run() {
	echo "== $1 [$2] =="
	echo "SQL: $3"
	ZIGHOUSE_CLICKBENCH_SUBMIT=1 "$ZH" query "$STORE" hits "$3" || echo " -> error"
	echo
}

run "count_all"            supported  "SELECT COUNT(*) FROM hits"
run "sum_with_filter"      supported  "SELECT SUM(Age) FROM hits WHERE EventDate >= '2013-07-15'"
run "min_max_date"        supported  "SELECT MIN(EventDate), MAX(EventDate) FROM hits"
run "count_distinct"      supported  "SELECT COUNT(DISTINCT CounterID) FROM hits"
run "groupby_counter"     supported  "SELECT CounterID, COUNT(*) FROM hits GROUP BY CounterID"
run "where_and"           supported  "SELECT COUNT(*) FROM hits WHERE Age > 25 AND EventDate >= '2013-07-10'"
run "groupby_topk"        supported  "SELECT CounterID, COUNT(*) AS c FROM hits GROUP BY CounterID ORDER BY c DESC LIMIT 10"
