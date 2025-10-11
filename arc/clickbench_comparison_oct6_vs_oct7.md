# ClickBench Comparison: Oct 6 vs Oct 7

## Configuration

| Metric | Oct 6 | Oct 7 |
|--------|-------|-------|
| Date | 2025-10-06 | 2025-10-07 |
| Workers | 28 (2x cores) | 42 (3x cores) |
| Cache | Disabled | Disabled |
| Machine | M3 Max (14 cores) | M3 Max (14 cores) |

## Overall Results

| Metric | Oct 6 | Oct 7 | Change |
|--------|-------|-------|--------|
| **Total Time** | **22.19s** | **23.54s** | **+6.1%** |
| Median Query | 0.242s | 0.233s | -3.6% |
| Faster queries | - | 24 | - |
| Slower queries | - | 19 | - |

## Top 10 Improvements

| Query | Oct 6 (s) | Oct 7 (s) | Change |
|-------|-----------|-----------|--------|
| Q19 | 1.688 | 1.643 | +2.7% |
| Q18 | 0.531 | 0.508 | +4.2% |
| Q20 | 0.058 | 0.036 | +37.4% |
| Q24 | 0.325 | 0.306 | +5.8% |
| Q30 | 0.065 | 0.048 | +25.7% |
| Q39 | 0.062 | 0.050 | +19.4% |
| Q16 | 0.242 | 0.233 | +3.6% |
| Q6 | 0.283 | 0.275 | +2.9% |
| Q4 | 0.061 | 0.053 | +13.3% |
| Q5 | 0.216 | 0.208 | +3.6% |

## Top 10 Regressions

| Query | Oct 6 (s) | Oct 7 (s) | Change |
|-------|-----------|-----------|--------|
| Q35 | 1.181 | 1.669 | -41.3% |
| Q29 | 7.895 | 8.127 | -2.9% |
| Q23 | 1.097 | 1.268 | -15.6% |
| Q22 | 0.519 | 0.682 | -31.4% |
| Q34 | 1.139 | 1.292 | -13.4% |
| Q21 | 0.613 | 0.743 | -21.1% |
| Q28 | 0.659 | 0.778 | -18.0% |
| Q33 | 1.053 | 1.122 | -6.5% |
| Q32 | 0.378 | 0.395 | -4.4% |
| Q10 | 0.341 | 0.348 | -2.0% |

## Analysis

### Key Findings:

1. **Overall Performance**: Oct 7 with 42 workers is 6.1% slower than Oct 6 with 28 workers
2. **Query Distribution**: 24 queries faster, 19 queries slower
3. **Context Switching**: More workers (42 vs 28) appears to introduce overhead for analytical queries

### Explanation:

The 42-worker configuration (3x cores) was optimized for **write throughput** (1.89M RPS),
which is I/O-bound (MinIO writes). However, ClickBench measures **analytical query performance**,
which is CPU-bound (DuckDB processing). For CPU-bound workloads, 28 workers (2x cores) appears
more optimal as it reduces context switching overhead.

### Recommendation:

Use different worker counts based on workload:
- **Write-heavy workload**: 42 workers (3x cores) → 1.89M RPS
- **Query-heavy workload**: 28 workers (2x cores) → 6% faster analytical queries
- **Mixed workload**: 28-35 workers (balance between throughput and latency)
