Diagnostic copy of `chdb/` for chdb-core 26.9.0. Not meant to be merged.

- `install` pins chdb-core to `v26.9.0` instead of the latest release.
- `create.sql` disables automatic statistics and forces LZ4 with adaptive codec selection off.
- `insert.sql` fixes `max_insert_threads` at 1.
- The measured load does not run `OPTIMIZE TABLE ... FINAL`.
- Before the measured query, `query` sets `max_threads_min_free_memory_per_thread=0`
  outside the timed region. This is the only change from the 26.9.0 LZ4/i1
  configuration and tests whether the read-side memory guard unnecessarily
  reduces two-vCPU machines to one query thread.
- The post-run load profiler from the release-candidate diagnostic is omitted
  because `v26.9.0` predates `benchmark/load_profile.py`. It was outside every
  measured window and does not affect the benchmark result.
