#!/bin/bash
# Arc ClickBench Benchmark Runner
# This script was used to generate the benchmark results

TRIES=3
PARQUET_FILE="hits.parquet"

python3 << 'EOF'
import duckdb
import time
import multiprocessing
from pathlib import Path

PARQUET_FILE = Path("hits.parquet")

# Connect to DuckDB
conn = duckdb.connect()

# Configure optimizations
cpu_count = multiprocessing.cpu_count()
conn.execute(f"SET threads TO {cpu_count}")
conn.execute("SET enable_object_cache TO true")

# Create view from parquet
conn.execute(f"CREATE SCHEMA IF NOT EXISTS clickbench")
conn.execute(f"CREATE VIEW clickbench.hits AS SELECT * FROM read_parquet('{PARQUET_FILE}')")

# Read queries
with open('queries.sql') as f:
    content = f.read()

queries = []
for query in content.split(';'):
    query = query.strip()
    if query and not query.startswith('--'):
        queries.append(query)

# Run each query 3 times
for i, query_sql in enumerate(queries, 1):
    for run in range(3):
        try:
            start = time.perf_counter()
            conn.execute(query_sql).fetchall()
            elapsed = time.perf_counter() - start
            print(f"{elapsed:.4f}")
        except Exception as e:
            print("null")
EOF
