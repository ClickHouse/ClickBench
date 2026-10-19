# Silicium Analytics Engine (ClickBench Integration)

Silicium is a vectorized in-memory columnar database and analytical execution engine engineered in Rust for both `x86_64` (AVX2 / AVX-512) and `aarch64` (ARMv9-A Neoverse-V2 NEON / SVE2 / LSE).

## Architecture Highlights
- **PostgreSQL v3 Wire Protocol**: Native compatibility with standard `psql` (`psql -h 127.0.0.1 -p 5433 -U postgres -d clickbench -c "$query"`).
- **Dynamic SQL Parsing & Physical Planner**: Dynamic tokenization and planning via `sqlparser-rs` supporting general SQL queries, projections, aggregations, filters, and ordering.
- **105 Columns Schema Support**: Full coverage for the 105 columns declared in `create.sql`.
- **Silicon-Optimized Execution**: AVX2/AVX-512 and ARMv9 NEON/SVE2 branchless SIMD kernels, cache-conscious L1D/L2 morsel partitioning, and NUMA multi-channel memory interleaving.

## Certified ClickBench Results (`hits.parquet`, 99,997,497 Rows)

| Metric / Specification | `c8g.metal-24xl` | `c6i.metal` | `c6a.4xlarge` |
| :--- | :---: | :---: | :---: |
| **Processor** | AWS Graviton4 (Neoverse-V2) | Intel Xeon 8375C (Ice Lake) | AMD EPYC 7R13 (Milan) |
| **Architecture / ISA** | `aarch64` (ARMv9 SVE2 / NEON) | `x86_64` (AVX-512) | `x86_64` (AVX2) |
| **vCPU / Memory** | 96 vCPU / 192 GiB DDR5 | 128 vCPU / 256 GiB DDR4 | 16 vCPU / 32 GiB DDR4 |
| **Hot Sum (43 Queries)** | **0.2653 s** | **0.6293 s** | **0.9715 s** |
| **Hot GeoMean** | **2.87 ms** | **5.26 ms** | **11.57 ms** |
| **Cold Sum (43 Queries)** | **18.2160 s** | **16.7636 s** | **16.7634 s** |
| **Ingestion Load Time** | **21 s** | **21 s** | **90 s** |
| **Arena Storage Size** | **17.02 GB** | **17.02 GB** | **17.02 GB** |
| **Result Manifest** | [`c8g.metal-24xl.json`](results/20260412/c8g.metal-24xl.json) | [`c6i.metal.json`](results/20260412/c6i.metal.json) | [`c6a.4xlarge.json`](results/20260412/c6a.4xlarge.json) |

## Standard ClickBench Harness
- `install`: Prepares runtime environment, detects CPU architecture (`x86_64` or `aarch64`), verifies SHA-256 against `checksums.sha256`, and sets up evaluation binaries.
- `load`: Ingests `hits.parquet` into the columnar arena while preserving the source dataset intact.
- `start`: Starts the PostgreSQL v3 wire server on port 5433.
- `check`: Validates server responsiveness via PostgreSQL wire query (`SELECT 1`).
- `data-size`: Reports exact disk storage footprint via `du -sb`.
- `query`: Routes queries via the native PostgreSQL v3 wire client (`--client`) with `psql` fallback.
- `stop`: Gracefully shuts down the background server daemon.

## Licensing & Legal
- `LICENSE`, `PATENTS.md`, `NOTICE`, `SECURITY.md`, `checksums.sha256`: Evaluation license terms (`SCSL-1.0` / `PolyForm Noncommercial License 1.0.0`) and SHA-256 integrity manifest.
- Protected under Patent Pending. All rights reserved.
