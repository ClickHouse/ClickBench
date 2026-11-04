# OpenSearch

The latest OpenSearch 3.x from the official APT repository, a single node, with the
security plugin in its demo configuration (HTTPS, the `admin` user), as the
Elasticsearch entry keeps security enabled. The only non-default setting is the JVM heap
(31 GB, as for Elasticsearch; the package default is 1 GB).

The index (`index_template.json`) follows the Elasticsearch entry: `_source` enabled, so
the documents are kept as they are (`retains_structure` is `yes`), one shard, no replicas,
`best_compression`, the index sorted by `kind`, `commit.operation`, `commit.collection`,
`did`, `time_us`, and the strings mapped dynamically as `keyword`. Differences:

- `commit.record` is not indexed (`"enabled": false`), it is only kept in `_source`. Its
  fields have different types in different collections (for example, `subject` is a
  string in follows and an object in likes), and with dynamic mapping the documents with
  the other type would be rejected. The Elasticsearch entry rewrote these documents with
  Filebeat processors instead; here the documents are loaded unchanged.
- `time_us` is a `long` (microseconds) rather than a `date`: there is no date format for
  epoch microseconds, and the Elasticsearch entry divided the values by 1000 in Filebeat.

The data is loaded with the `_bulk` API (`bulk-load.py`, four files at a time, four
concurrent requests of 5000 documents per file), dropping the few lines that are not valid
JSON, then force-merged to one segment, as in the Elasticsearch entry.

The queries (`queries.json`) are search requests with aggregations (the query DSL), sent
with `request_cache=false` (the shard request cache would otherwise return the cached
result in the hot runs); the runtime is the `took` of the response. The SQL and PPL plugins
do not report a server-side time.

- Q2 uses `cardinality` with `precision_threshold` 40000 (the maximum), which is
  approximate (HyperLogLog++) above the threshold, as `COUNT_DISTINCT` in the
  Elasticsearch entry: OpenSearch has no exact distinct count in a single request.
- Q3 extracts the hour of the day with a Painless script in a `terms` aggregation.
- Q4 is a `terms` aggregation on `did` ordered by the `min` of `time_us`, which is exact
  with one shard.
- Q5 has no aggregation for `max - min` per group that can be sorted (a `bucket_sort`
  needs all the users in buckets, more than `search.max_buckets`), so it is a
  `scripted_metric` that keeps the first and last time of every user and the top 3 spans;
  it is exact with one shard and one segment, which the force merge makes.
