# Quickwit

[Quickwit](https://quickwit.io) is a Rust-based search engine for log analytics, built on top of [Tantivy](https://github.com/quickwit-oss/tantivy). It exposes an Elasticsearch-compatible REST API for ingestion and search, but does not implement an SQL endpoint, so this benchmark uses the native Elasticsearch query DSL directly.

## Methodology

Infrastructure:
- Single-node Quickwit **v0.9.0-rc** (Docker `quickwit/quickwit:v0.9.0-rc`).

  Stable **0.8.2** is missing `cardinality`, `wildcard`, and several other features the benchmark relies on, so we use the v0.9 release candidate. The v0.9 line is still unreleased — as soon as a stable v0.9.x ships, bump `QW_IMAGE` in `benchmark.sh`.

Index configuration (`index_config.yaml`):
- All scalar fields declared with `fast: true` so they can participate in aggregations and sorts.
- Keyword-like text fields use the `raw` tokenizer with the `raw` fast-field normalizer to mimic Elasticsearch's `keyword` mapping.
- `EventTime` is set as the index's timestamp field, providing time-based pruning.

Ingestion (`benchmark.sh`):
- Streams `hits.json.gz` decompressed into `quickwit tool local-ingest`, which builds splits directly on local storage. We do **not** use the Elasticsearch bulk endpoint: v0.9's sharded ingest-v2 API caps single-node throughput to a few MB/s in our testing and stalls waiting for shards to scale. `local-ingest` bypasses the ingest pipeline entirely.
- The server picks up the new splits on its next metastore poll (default 30 s).

Queries (`queries.json`):
- Each query in `queries.sql` is hand-translated to the Elasticsearch DSL on the corresponding line of `queries.json`, and submitted to `/api/v1/_elastic/hits/_search`.
- Timing is taken from the `took` field returned by Quickwit (milliseconds, engine-internal).
- Queries that are not expressible in Quickwit's DSL are recorded as `null`.

## Unsupported queries

The following ClickBench queries cannot currently be expressed in Quickwit's Elasticsearch-compatible DSL and are reported as `null`:

| Q  | Reason                                                                |
|----|-----------------------------------------------------------------------|
| 19 | `extract(minute FROM …)` — no scripted/runtime fields                 |
| 26 | `ORDER BY` on text field — `sort by field on type text is currently not supported` |
| 27 | `ORDER BY` on text field                                              |
| 28 | `AVG(length(URL))` — no scripted/runtime fields                       |
| 29 | `REGEXP_REPLACE` — not supported                                      |
| 30 | `SUM(col + N)` — no scripted aggregations                             |
| 36 | `ClientIP - N` — no scripted aggregations                             |
| 40 | `CASE WHEN …` — no scripted/runtime fields                            |

All other 35 queries run through the native Elasticsearch DSL, including `cardinality` (Q5/6/9/10/11/12/14) and `wildcard` (Q21/22/23/24).

## Running

```bash
bash benchmark.sh
```

Installs Docker and Quickwit, creates the index, downloads `hits.json.gz`, runs `local-ingest`, then runs `run.sh` to time each query three times with caches dropped between runs.
