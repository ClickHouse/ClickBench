# Quickwit

[Quickwit](https://quickwit.io) is a Rust-based search engine for log analytics, built on top of [Tantivy](https://github.com/quickwit-oss/tantivy). It exposes an Elasticsearch-compatible REST API for ingestion and search, but does not implement an SQL endpoint, so this benchmark uses the native Elasticsearch query DSL directly.

## Methodology

Infrastructure:
- Single-node Quickwit 0.8.2 on AWS EC2 c6a.4xlarge

Index configuration (`index_config.yaml`):
- All scalar fields declared with `fast: true` so they can participate in aggregations and sorts (Quickwit aggregations require fast fields).
- Keyword-like text fields use the `raw` tokenizer with the `raw` fast-field normalizer to mimic Elasticsearch's `keyword` mapping.
- `EventTime` is set as the index's timestamp field, providing time-based pruning.

Ingestion (`load.py`):
- Reads `hits.json.gz` and streams NDJSON to the Elasticsearch-compatible bulk endpoint at `/api/v1/_elastic/hits/_bulk`.
- Quickwit's bulk endpoint only honors the `create` action, and rejects payloads >10MB, so batches are smaller than the Elasticsearch loader.

Queries (`queries.json`):
- Each query in `queries.sql` is hand-translated to the Elasticsearch DSL on the corresponding line of `queries.json`, and submitted to `/api/v1/_elastic/hits/_search`.
- Timing is taken from the `took` field returned by Quickwit (milliseconds, engine-internal).
- Queries that are not expressible in Quickwit's DSL are recorded as `null`.

## Unsupported queries

Quickwit's aggregation and query model is narrower than Elasticsearch's. The following ClickBench queries cannot currently be expressed and are reported as `null`:

| Q  | Reason                                                                |
|----|-----------------------------------------------------------------------|
| 5  | `COUNT(DISTINCT)` — Quickwit has no `cardinality` aggregation         |
| 6  | `COUNT(DISTINCT)`                                                     |
| 9  | `COUNT(DISTINCT)`                                                     |
| 10 | `COUNT(DISTINCT)`                                                     |
| 11 | `COUNT(DISTINCT)`                                                     |
| 12 | `COUNT(DISTINCT)`                                                     |
| 14 | `COUNT(DISTINCT)`                                                     |
| 19 | `extract(minute FROM …)` — no scripted/runtime fields                 |
| 21 | `LIKE '%…%'` — leading wildcards rejected, no `wildcard`/`regexp`     |
| 22 | `LIKE '%…%'`                                                          |
| 23 | `COUNT(DISTINCT)`                                                     |
| 24 | `LIKE '%…%'`                                                          |
| 26 | `ORDER BY` on text field — not supported by the search backend        |
| 27 | `ORDER BY` on text field                                              |
| 28 | `AVG(length(URL))` — no scripted/runtime fields                       |
| 29 | `REGEXP_REPLACE` — not supported                                      |
| 30 | `SUM(col + N)` — no scripted aggregations                             |
| 36 | `ClientIP - N` — no scripted aggregations                             |
| 40 | `CASE WHEN …` — no scripted/runtime fields                            |

All other queries run through the native Elasticsearch DSL.

## Running

```bash
bash benchmark.sh
```

This installs Quickwit, creates the index, downloads `hits.json.gz`, ingests the data via the ES bulk API, and then runs `run.sh` to time each query three times with caches dropped between runs.
