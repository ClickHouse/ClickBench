# CORTEX Embedded Analytics Engine — ClickBench Integration

High-performance native analytical engine integration for ClickBench.

## System Details
- **Architecture**: In-Process Native C-ABI / Rust Engine (AVX2 / AVX-512 Data-Oriented Design)
- **Interface**: Zero-copy memory-mapped columnar arena (`.cortex_col`)
- **Execution Model**: Embedded (`BENCH_RESTARTABLE=no`, `BENCH_DURABLE=yes`)
- **Distribution Model**: Precompiled evaluation binaries fetched at install time with SHA-256 verification.

## Reproduction
To run the official ClickBench benchmark on this system:
```bash
./benchmark.sh
```

## Intellectual Property & License
- Benchmark harness scripts, SQL queries, and runner: MIT License.
- Precompiled evaluation binaries (`libcortex_clickbench_arena.so`, `cortex_ingest`): Floria Community Software License (FCSL-1.0) / MIT Evaluation License.
- Protected under Canadian Patent Application CIPO CA 3,322,620 and international counterparts. All rights reserved.
- Floria Laboratoire Inc.
