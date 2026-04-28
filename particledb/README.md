# ParticleDB ClickBench Submission

[ParticleDB](https://particledb.ai) is a Rust HTAP (Hybrid Transactional/Analytical Processing) database that combines OLTP and OLAP workloads in a single engine. Source code is available at [github.com/particledb-ai](https://github.com/particledb-ai).

## Architecture

- **Storage format**: Apache Arrow columnar format with dictionary encoding for low-cardinality strings
- **Execution**: Columnar analytical engine with parallel query execution via Rayon thread pool
- **Type mapping**: All integers stored as BIGINT (i64), all strings as VARCHAR, TIMESTAMP as BIGINT (epoch seconds), DATE as VARCHAR ('YYYY-MM-DD')

## Key Optimizations for ClickBench

- **Zone-level precomputed aggregation**: Per-chunk SUM/COUNT/MIN/MAX stats resolve ungrouped aggregates in O(chunks) instead of O(rows). Tri-state filter classification (ALL/NONE/PARTIAL) skips entire chunks.
- **Chunk group stats**: For columns with <=32 distinct values, per-group SUM/COUNT/MIN/MAX are precomputed at load time. GROUP BY queries resolve from chunk summaries.
- **Fused scan paths**: Single-pass filter+aggregate avoids intermediate RecordBatch materialization. Monomorphized dispatch generates SIMD-friendly code per filter/agg combination.
- **Contiguous flat column cache**: Columns concatenated into single contiguous Vec for hardware prefetcher efficiency.
- **Cost-based aggregation dispatch**: Automatic selection between low-cardinality SIMD masks, dense-array direct accumulation, and radix-partitioned hash tables based on group count and data distribution.

## Hardware Requirements

- **c8g.metal-48xl** (192 vCPUs, 384 GB RAM) used for the submitted full 100M-row hits.parquet result
- The submitted result includes the full load time from `hits.parquet`

## Running

```bash
# Full automated setup on a fresh Ubuntu 24.04 VM
./benchmark.sh

# If already built and data is downloaded
./run.sh
```

## Data Loading

The benchmark loads all 100M rows from `hits.parquet` and projects the 25 columns referenced by the 43 official queries.

The included `create.sql` and `queries.sql` files are the official ClickBench SQL reference files. The ParticleDB benchmark harness applies ParticleDB's type mapping and column projection during load.

## Results Format

The test harness outputs ClickBench-compatible JSON with 3 runs per query:
```json
{
  "system": "ParticleDB",
  "result": [
    [run1_seconds, run2_seconds, run3_seconds],
    ...
  ]
}
```
