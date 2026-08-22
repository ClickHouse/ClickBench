# ScramDB (tuned)

`tuned: yes` companion to [`scramdb`](../scramdb). Same image, harness and
schema, only the config differs. See that README for the rest.

    bash benchmark.sh

This configuration has been validated against all 43 queries on the full
dataset.

## Tuned

- `[storage.io] backend = "buffered"`: reads go through the OS page cache, so
  a cold read pays disk once and every warm re-read of a hot byte is RAM
- `buffer_pool_percent = 0` (auto: 15% on the buffered backend, where the
  page cache is the primary read cache and a large private pool would hold
  the same bytes twice)
- `execution_memory_percent` 25, `working_set_percent` 85
- compiled-query cache 256MB memory / 1GB disk: 43 distinct query kernels
  need only a few MiB; a larger cache takes memory from execution
- `morsel_size` 8MB, `arena_chunk_size` 8MB
- `copy_batch_rows` 131072, `copy_pipeline_depth` 8 (load path only)
- `spill_agg_partitions` 128 - the high-cardinality GROUP BY and exact
  COUNT(DISTINCT) queries all spill
- `prefetch_depth` 32, `prefetch_queue_depth` 256, `bloom_max_bytes` 16KB
- `flush_threshold_rows` 65536
- background compaction, GC and auto-analyze pushed past the run length; the
  driver restarts before all 43 queries, so nothing wakes mid-query
- `analyze_on_load` off; `./load` runs the one explicit `ANALYZE` instead
- UDF and GPU lanes off, so neither reserves memory from the budget
- shutdown drain 5s, for the harness's per-query cold restart cycle

Join knobs are untouched (no joins in the 43 queries).
