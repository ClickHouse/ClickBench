#!/bin/bash
# ParticleDB ClickBench Runner
#
# Each query is executed 3 times; the test reports cold (run 1) and hot
# (best of runs 2-3) timings along with a full submission JSON.

set -euo pipefail

echo "Ensure hits.parquet is at benchmarks/clickbench/data/hits.parquet"
echo ""
echo "Running benchmark..."

CLICKBENCH_MACHINE="${CLICKBENCH_MACHINE:-c8g.metal-48xl}" \
    cargo test -p spanner-integration-tests --release test_clickbench_real_hits -- --nocapture 2>&1 | tee /tmp/clickbench_results.log

# Extract the submission JSON
echo ""
echo "Extracting submission JSON..."
mkdir -p results
sed -n '/CLICKBENCH_SUBMISSION_JSON_START/,/CLICKBENCH_SUBMISSION_JSON_END/p' \
    /tmp/clickbench_results.log | grep -v 'CLICKBENCH_SUBMISSION_JSON' > results/c8g.metal-48xl.json
echo "Results written to results/c8g.metal-48xl.json"
