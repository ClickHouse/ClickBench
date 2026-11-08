# OpenSearch

The latest OpenSearch 3.x from the official APT repository, a single node with the
default settings, except:

- the security plugin is disabled (plain HTTP, no users), as the Elasticsearch entry
  disables X-Pack security;
- the JVM heap is half of the memory, at most 31 GB, which is what Elasticsearch chooses
  by itself (the default of the package is 1 GB).

The index (`index.json`) has one shard and no replicas, with the columns typed as in
ClickHouse (`short`, `integer`, `long`, `keyword`, `date`) and the index sorted by the
primary key of ClickHouse (`CounterID`, `EventDate`, `UserID`, `EventTime`, `WatchID`),
as in the Elasticsearch entry. `_source` is enabled.

The data (`hits.json.gz`) is loaded with the `_bulk` API (`bulk-load.py`: batches of
10000 documents, eight requests in flight), and the load checks that all 99997497
documents are in the index. As in the Elasticsearch entry, the load time includes the
download of `hits.json.gz`, which is decompressed on the fly.

The queries (`queries.sql`, named so for the Playground, but JSON) are search requests with aggregations (the query DSL),
written by hand from the SQL queries, as in the OpenSearch entry of the JSON benchmark
(`../json/opensearch`). OpenSearch has no endpoint to translate SQL to the query DSL
(the Elasticsearch entry uses `_sql/translate`), and its SQL plugin does not report a
server-side time. They are sent with `request_cache=false` (the shard request cache
would otherwise return the cached result in the second and third tries); the runtime is
the `took` of the response, as in the Elasticsearch entry.

- `GROUP BY` is a `terms` aggregation, or `multi_terms` for several keys (also the keys
  that are expressions, with Painless scripts: Q19, Q36, Q40), and `date_histogram` for
  `DATE_TRUNC('minute', ...)` (Q43). `GROUP BY` without `ORDER BY` (Q18) is a
  `composite` aggregation.
- `COUNT(DISTINCT)` is exact: a `scripted_metric` that collects the set of the values
  (`cardinality` is approximate, HyperLogLog++). In the buckets of a `terms` aggregation
  ordered by the count (Q10, Q23), it is a sub-aggregation. A bucket aggregation cannot
  be ordered by a `scripted_metric`, so `ORDER BY COUNT(DISTINCT UserID) DESC LIMIT 10`
  (Q9, Q11, Q12, Q14) is one top-level `scripted_metric` with a set per group, which its
  reduce script sorts; it returns `[key, count]` pairs (in Q12, the two keys joined by a
  space).
- The top-N by count (`ORDER BY COUNT(*) DESC LIMIT N`) is approximate: OpenSearch 3.x
  runs the aggregations with concurrent segment search by default, and each slice of the
  shard returns only its top `size * 1.5 + 10` buckets, as the shards do in a multi-shard
  index. On a sample, the top groups of Q13, Q16, Q17, Q36, Q40, and Q41 differ from the
  exact result; they match with `index.search.concurrent_segment_search.mode: none`.
- `LIMIT x OFFSET y` (Q39-Q43) takes the first `x + y` groups and a `bucket_sort` with
  `from: y`.
- `MIN` of a string column (Q22, Q23, Q29) is `top_hits` of one document sorted by the
  column.
- `LIKE '%google%'` is a `wildcard` query.
- `length` (Q28, Q29) is the length of the Java string in UTF-16 code units, not in bytes
  as in ClickHouse.
- `HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25` (Q28, Q29) takes the top 1000
  groups by count with `min_doc_count` and then orders them by `l` with a `bucket_sort`:
  a `terms` aggregation ordered by `l` would select its top buckets by `l` before applying
  `min_doc_count`, and at most 999 groups of the table have more than 100000 rows.
- `REGEXP_REPLACE` (Q29) is a Painless script with string functions that returns the
  same as the regular expression (Painless regular expressions are limited by default).
- `SUM(ResolutionWidth + k)` (Q30) is a `sum` of a script for every `k`.
- The constant in `GROUP BY 1, URL` (Q35) is not a grouping key.
