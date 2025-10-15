#!/usr/bin/env python3
"""
Compare current JSON results with previous benchmark
"""

import json
import statistics

# Read previous results
with open('results/m3_max_cache_disabled.json', 'r') as f:
    previous = json.load(f)
    previous_times = [[min(run) for run in previous['result']]]  # Best of 3 runs for each query

# Read current JSON results
with open('results_json.txt', 'r') as f:
    json_lines = [line.strip() for line in f if line.strip()]
    # Skip the first 5 lines (header messages) and "Benchmark complete!"
    json_times = []
    for line in json_lines[5:]:  # Skip header
        if line != "Benchmark complete!":
            try:
                json_times.append(float(line))
            except ValueError:
                pass

# Group current results by query (3 runs per query)
num_queries = len(json_times) // 3
current_queries = []

for i in range(num_queries):
    json_run = json_times[i*3:(i+1)*3]
    current_queries.append(min(json_run))  # Best time

# Get previous best times
previous_queries = [min(run) for run in previous['result']]

# Calculate statistics
print("=" * 80)
print("ClickBench Comparison: Previous vs Current (JSON endpoint)")
print("=" * 80)
print(f"\nTotal queries: {num_queries}")
print(f"\nPrevious benchmark (2025-10-12):")
print(f"  Total time: {sum(previous_queries):.2f}s")
print(f"  Average:    {statistics.mean(previous_queries):.4f}s")
print(f"  Median:     {statistics.median(previous_queries):.4f}s")
print(f"\nCurrent benchmark:")
print(f"  Total time: {sum(current_queries):.2f}s")
print(f"  Average:    {statistics.mean(current_queries):.4f}s")
print(f"  Median:     {statistics.median(current_queries):.4f}s")

speedup = sum(previous_queries) / sum(current_queries)
improvement = (sum(previous_queries) - sum(current_queries)) / sum(previous_queries) * 100

print(f"\n📊 Overall change: {speedup:.2f}x")
print(f"   Improvement: {improvement:+.1f}%")

# Per-query comparison
print(f"\n" + "=" * 80)
print("Per-Query Comparison (best of 3 runs)")
print("=" * 80)
print(f"{'Query':<8} {'Previous (s)':<14} {'Current (s)':<14} {'Change':<10} {'Diff'}")
print("-" * 80)

faster_count = 0
slower_count = 0
same_count = 0

for i in range(num_queries):
    prev_time = previous_queries[i]
    curr_time = current_queries[i]
    change = prev_time / curr_time
    diff = (prev_time - curr_time) / prev_time * 100

    if change > 1.05:
        faster_count += 1
        marker = "✅ faster"
    elif change < 0.95:
        slower_count += 1
        marker = "❌ slower"
    else:
        same_count += 1
        marker = "➡️ same"

    print(f"Q{i+1:<7} {prev_time:<14.4f} {curr_time:<14.4f} {change:<10.2f}x {diff:>6.1f}% {marker}")

print("=" * 80)
print(f"\nSummary:")
print(f"  Faster: {faster_count} queries ({faster_count/num_queries*100:.1f}%)")
print(f"  Slower: {slower_count} queries ({slower_count/num_queries*100:.1f}%)")
print(f"  Same:   {same_count} queries ({same_count/num_queries*100:.1f}%)")
print("=" * 80)
