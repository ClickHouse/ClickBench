# ClickBench Official Results Directory

Results in this directory must be generated exclusively by the official ClickBench benchmark runner (`../lib/benchmark-common.sh`) adhering strictly to:
1. `BENCH_RESTARTABLE="yes"` with active daemon restart and Linux `drop_caches`.
2. Exact query elapsed timings reported on `stderr` via `./query`.
3. Complete dataset downloaded via `BENCH_DOWNLOAD_SCRIPT="download-hits-parquet-single"`.
4. Arbitrary relational SQL execution over all 105 columns with zero query-specific hardcoded dispatch.

All historical pre-Option A runs from 2026-10-06 have been purged due to upstream rejection (PR #2427).
