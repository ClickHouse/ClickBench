#!/bin/bash
# Arc ClickBench Benchmark Runner
# Queries Arc via HTTP API using Apache Arrow columnar format

TRIES=3
DATABASE="${DATABASE:-clickbench}"
TABLE="${TABLE:-hits}"
ARC_URL="${ARC_URL:-http://localhost:8000}"
ARC_API_KEY="${ARC_API_KEY:-benchmark-test-key}"

# Check if Arc is running
echo "Checking if Arc is running at $ARC_URL..." >&2
if ! curl -s -f "$ARC_URL/health" > /dev/null 2>&1; then
    echo "Error: Arc is not running at $ARC_URL" >&2
    echo "Please start Arc first or set ARC_URL environment variable" >&2
    exit 1
fi

echo "Arc is running. Querying table: $DATABASE.$TABLE (Apache Arrow)" >&2
echo "Using API key: ${ARC_API_KEY:0:20}..." >&2

python3 << EOF
import requests
import time
import sys

try:
    import pyarrow as pa
except ImportError:
    print("Error: pyarrow is required for Arrow format", file=sys.stderr)
    print("Install with: pip install pyarrow", file=sys.stderr)
    sys.exit(1)

ARC_URL = "$ARC_URL"
API_KEY = "$ARC_API_KEY"
DATABASE = "$DATABASE"
TABLE = "$TABLE"

# Headers for API requests
headers = {
    "x-api-key": API_KEY,
    "Content-Type": "application/json"
}

# Read queries
with open('queries.sql') as f:
    content = f.read()

# Remove comment lines
lines = [line for line in content.split('\n') if not line.strip().startswith('--')]
clean_content = '\n'.join(lines)

# Split by semicolons and filter empties
queries = []
for query in clean_content.split(';'):
    query = query.strip()
    if query:
        queries.append(query)

print(f"Running {len(queries)} queries via Apache Arrow API...", file=sys.stderr)

# Run each query 3 times
for i, query_sql in enumerate(queries, 1):
    for run in range(3):
        # Flush filesystem cache before first run only (ClickBench requirement)
        if run == 0:
            import subprocess
            try:
                subprocess.run(['sync'], check=False)
                subprocess.run(['sudo', 'sh', '-c', 'echo 3 > /proc/sys/vm/drop_caches'],
                             check=False, stderr=subprocess.DEVNULL)
            except:
                pass  # Ignore errors if not on Linux or no sudo access
        try:
            start = time.perf_counter()

            response = requests.post(
                f"{ARC_URL}/api/v1/query/arrow",
                headers=headers,
                json={"sql": query_sql},
                timeout=300
            )

            if response.status_code == 200:
                # Parse Arrow IPC stream to ensure data is received
                reader = pa.ipc.open_stream(response.content)
                arrow_table = reader.read_all()
                elapsed = time.perf_counter() - start
                print(f"{elapsed:.4f}")
            else:
                print("null")
                if run == 0:
                    print(f"Query {i} failed: {response.status_code} - {response.text[:200]}", file=sys.stderr)
        except requests.exceptions.Timeout:
            print("null")
            if run == 0:
                print(f"Query {i} timed out", file=sys.stderr)
        except Exception as e:
            print("null")
            if run == 0:
                print(f"Query {i} error: {e}", file=sys.stderr)

print("Benchmark complete!", file=sys.stderr)
EOF
