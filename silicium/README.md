# Silicium Analytics Engine (ClickBench Integration)

Silicium is a vectorized in-memory columnar database and analytical execution engine engineered in Rust.

## Architecture Highlights
- **PostgreSQL v3 Wire Protocol**: Native compatibility with standard `psql` (`psql -h 127.0.0.1 -p 5433 -U postgres -d clickbench -c "$query"`).
- **Dynamic SQL Parsing & Physical Planner**: Dynamic tokenization and planning via `sqlparser-rs` supporting general SQL queries, projections, aggregations, filters, and ordering.
- **105 Columns Schema Support**: Full coverage for the 105 columns declared in `create.sql`.
- **Silicon-Optimized Execution**: AVX2/AVX-512 branchless SIMD kernels, cache-conscious L1D/L2 morsel partitioning, and NUMA multi-channel memory interleaving.

## Standard ClickBench Harness
- `install`: Prepares runtime environment, checks CPU capabilities, and sets up binaries.
- `load`: Ingests `hits.parquet` into high-performance columnar arena.
- `start`: Starts the PostgreSQL v3 wire server on port 5433.
- `check`: Validates server responsiveness via SQL probe query (`SELECT COUNT(*) FROM hits;`).
- `data-size`: Reports exact disk storage footprint via `du -sb`.
- `query`: Routes queries via `psql` (with direct CLI runner fallback).
- `stop`: Gracefully shuts down the background server daemon.

## Licensing
- Evaluation License: PolyForm Noncommercial License 1.0.0 / SCSL-1.0 Research Evaluation License.
- Patent Pending: All rights reserved.
