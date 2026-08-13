# ScramDB (tuned)

`tuned: yes` companion to [`scramdb`](../scramdb). Same image and harness, only
the config differs. See that README for the rest.

    bash benchmark.sh

**None of this has been measured against these 43 queries yet.** It is reasoned
from the engine's defaults, not from a sweep.

## Tuned

- `backend = "io_uring"` (base stays on the `auto` default)
- `morsel_size` 8MB, `arena_chunk_size` 8MB
- `copy_batch_rows` 131072, `copy_pipeline_depth` 8 (load path only)
- `spill_agg_partitions` 128 - the high-cardinality GROUP BY and exact
  COUNT(DISTINCT) queries all spill
- `prefetch_depth` 32, `prefetch_queue_depth` 256, `bloom_max_bytes` 16KB
- `flush_threshold_rows` 65536
- background compaction, GC and auto-analyze pushed past the run length; the
  driver restarts before all 43 queries, so nothing should wake mid-query

Memory and segment sizing stay at product defaults; join knobs are untouched
(no joins in the 43 queries).
