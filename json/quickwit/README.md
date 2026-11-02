# Quickwit

Ported from the JSONBench pull request https://github.com/ClickHouse/JSONBench/pull/104.

Quickwit has no SQL endpoint. The queries in `queries.json` are search requests in
Quickwit's native JSON query language, sent to `/api/v1/jsonbench/search`; the runtime
is `elapsed_time_micros` of the response. The documents are loaded with
`quickwit tool local-ingest`.

Settings different from the defaults (`quickwit.yaml`):

- `searcher.aggregation_memory_limit` and `searcher.request_timeout_secs` are raised,
  as in the PR: the aggregations on `did` do not run at all at 100m and 1000m documents
  with the defaults.
- `searcher.partial_request_cache.capacity` is 0: the partial request cache keeps the
  per-split leaf search results, which JSONBench does not allow between hot runs.

Queries that are recorded as null:

- Q3 (events per hour of the day): Quickwit has no scripted fields, so there is no way to
  extract the hour of the day. The PR used a `date_histogram` with a `fixed_interval` of
  `1h`, which counts per absolute hour (one bucket for each hour of each day), a different
  result:
  `{"query":"kind:commit AND commit.operation:create AND commit.collection:IN [app.bsky.feed.post app.bsky.feed.repost app.bsky.feed.like]","max_hits":0,"aggs":{"events":{"terms":{"field":"commit.collection","order":{"_key":"asc"},"size":1000},"aggs":{"hour_of_day":{"date_histogram":{"field":"time_us","fixed_interval":"1h"}}}}}}`
- Q5 (the longest activity span): there is no `bucket_script` to compute `max - min`. The
  PR ordered the users by `max(time_us)` instead, a different result.

Q2 uses `cardinality`, which is approximate (HyperLogLog), like `COUNT_DISTINCT` in the
Elasticsearch entry; the counts differ from the exact ones by less than 0.2%.
