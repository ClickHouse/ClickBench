#!/usr/bin/env python3
"""
Compare ClickBench results between JSON and Arrow endpoints
"""

import statistics

# Read JSON results
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

# Read Arrow results
with open('results_arrow.txt', 'r') as f:
    arrow_lines = [line.strip() for line in f if line.strip()]
    # Skip the first 5 lines (header messages) and "Benchmark complete!"
    arrow_times = []
    for line in arrow_lines[5:]:  # Skip header
        if line != "Benchmark complete!":
            try:
                arrow_times.append(float(line))
            except ValueError:
                pass

# Group by query (3 runs per query)
num_queries = len(json_times) // 3
json_queries = []
arrow_queries = []

for i in range(num_queries):
    json_run = json_times[i*3:(i+1)*3]
    arrow_run = arrow_times[i*3:(i+1)*3]
    json_queries.append(min(json_run))  # Best time
    arrow_queries.append(min(arrow_run))  # Best time

# Calculate statistics
print("=" * 80)
print("ClickBench Results Comparison: JSON vs Arrow")
print("=" * 80)
print(f"\nTotal queries: {num_queries}")
print(f"\nJSON endpoint:")
print(f"  Total time: {sum(json_queries):.2f}s")
print(f"  Average:    {statistics.mean(json_queries):.4f}s")
print(f"  Median:     {statistics.median(json_queries):.4f}s")
print(f"\nArrow endpoint:")
print(f"  Total time: {sum(arrow_queries):.2f}s")
print(f"  Average:    {statistics.mean(arrow_queries):.4f}s")
print(f"  Median:     {statistics.median(arrow_queries):.4f}s")

speedup = sum(json_queries) / sum(arrow_queries)
print(f"\n📊 Overall speedup: {speedup:.2f}x")

# Per-query comparison
print(f"\n" + "=" * 80)
print("Per-Query Comparison (best of 3 runs)")
print("=" * 80)
print(f"{'Query':<8} {'JSON (s)':<12} {'Arrow (s)':<12} {'Speedup':<10} {'Improvement'}")
print("-" * 80)

faster_count = 0
slower_count = 0
same_count = 0

for i in range(num_queries):
    json_time = json_queries[i]
    arrow_time = arrow_queries[i]
    query_speedup = json_time / arrow_time
    improvement = (json_time - arrow_time) / json_time * 100

    if query_speedup > 1.05:
        faster_count += 1
        marker = "🚀"
    elif query_speedup < 0.95:
        slower_count += 1
        marker = "⚠️"
    else:
        same_count += 1
        marker = "➡️"

    print(f"Q{i+1:<7} {json_time:<12.4f} {arrow_time:<12.4f} {query_speedup:<10.2f}x {improvement:>6.1f}% {marker}")

print("=" * 80)
print(f"\nSummary:")
print(f"  Faster: {faster_count} queries ({faster_count/num_queries*100:.1f}%)")
print(f"  Slower: {slower_count} queries ({slower_count/num_queries*100:.1f}%)")
print(f"  Same:   {same_count} queries ({same_count/num_queries*100:.1f}%)")
print("=" * 80)
