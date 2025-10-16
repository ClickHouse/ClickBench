# Arc - ClickBench Benchmark

Arc is a high-performance time-series data warehouse built on DuckDB, Parquet, and object storage.

## System Information

- **System:** Arc
- **Date:** 2025-10-15
- **Machine:** m3_max (14 cores, 36GB RAM)
- **Tags:** Python, time-series, DuckDB, Parquet, columnar, HTTP API
- **License:** AGPL-3.0
- **Repository:** https://github.com/Basekick-Labs/arc

## Performance

Arc achieves:
- **Write throughput:** 1.89M records/sec (MessagePack binary protocol)
- **ClickBench:** ~22 seconds total (43 analytical queries)
- **Storage:** DuckDB + Parquet with MinIO/S3/GCS backends

## Prerequisites

- Ubuntu/Debian Linux (or compatible)
- Python 3.11+
- 8GB+ RAM recommended
- Internet connection for dataset download
- Sudo access (only if system dependencies are missing)

## Quick Start

The benchmark script handles everything automatically:

```bash
./benchmark.sh
```

This will:
1. Create Python virtual environment (no system packages modified)
2. Clone Arc repository
3. Install dependencies in venv
4. Start Arc server with optimal worker count (2x CPU cores)
5. Download ClickBench dataset (14GB parquet file)
6. Run 43 queries × 3 iterations
7. Output results in ClickBench JSON format

## Manual Steps

### 1. Install Dependencies

```bash
sudo apt-get update -y
sudo apt-get install -y python3-pip python3-venv wget curl
```

### 2. Create Virtual Environment

```bash
python3 -m venv arc-venv
source arc-venv/bin/activate
```

### 3. Clone and Setup Arc

```bash
git clone https://github.com/Basekick-Labs/arc.git
cd arc
pip install -r requirements.txt
mkdir -p data logs
```

### 4. Create API Token

```bash
python3 << 'EOF'
from api.auth import AuthManager

auth = AuthManager(db_path='./data/arc.db')
token = auth.create_token(name='clickbench', description='ClickBench benchmark')
print(f"Token: {token}")
EOF
```

### 5. Start Arc Server

```bash
# Auto-detect cores
CORES=$(nproc)
WORKERS=$((CORES * 2))

# Start server
gunicorn -w $WORKERS -b 0.0.0.0:8000 \
    -k uvicorn.workers.UvicornWorker \
    --timeout 300 \
    api.main:app
```

### 6. Download Dataset

```bash
wget https://datasets.clickhouse.com/hits_compatible/hits.parquet
```

### 7. Run Benchmark

```bash
export ARC_URL="http://localhost:8000"
export ARC_API_KEY="your-token-from-step-4"
export DATABASE="clickbench"
export TABLE="hits"

./run.sh
```

**Note:** The benchmark uses Apache Arrow columnar format for optimal performance. Requires `pyarrow` to be installed.

## Configuration

Arc uses optimal settings for ClickBench (all automatic, no configuration needed):

- **Workers:** Auto-detected cores × 2 (optimal for analytical workloads)
- **Query cache:** Disabled (per ClickBench rules)
- **Storage:** Local filesystem (fastest for single-node)
- **Timeout:** 300 seconds per query
- **Format:** Apache Arrow (columnar, high-performance)

## Results Format

Results are output in official ClickBench format:

```
Load time: 0
Data size: 14779976446
[0.0226, 0.0233, 0.0284]
[0.0324, 0.0334, 0.0392]
...
```

- **Load time:** Arc queries Parquet files directly without a data loading phase (load time = 0)
- **Data size:** Size of the dataset in bytes (14GB)
- **Query results:** 43 lines, each containing 3 execution times (in seconds) for the same query

## Notes

- **Virtual Environment:** All dependencies installed in isolated venv (no `--break-system-packages` needed)
- **Authentication:** Uses Arc's built-in token auth (simpler than Permission-based auth)
- **Query Cache:** Disabled to ensure fair benchmark (no cache hits)
- **Worker Count:** Auto-detected based on CPU cores, optimized for analytical workloads
- **Timeout:** Generous 300s timeout for complex queries

## Architecture

```
ClickBench Query → Arc Arrow API → DuckDB → Parquet File → Arrow Results
```

Arc queries the Parquet file directly via DuckDB's `read_parquet()` function and returns results in Apache Arrow columnar format for maximum efficiency.

## Performance Characteristics

Arc is optimized for:
- **High-throughput writes** (1.89M RPS with MessagePack)
- **Analytical queries** (DuckDB's columnar engine)
- **Columnar data transfer** (Apache Arrow IPC for efficient results)
- **Object storage** (S3, GCS, MinIO compatibility)
- **Time-series workloads** (built-in time-based indexing)

## Support

- GitHub: https://github.com/Basekick-Labs/arc
- Issues: https://github.com/Basekick-Labs/arc/issues
- Docs: https://docs.arc.basekick.com (coming soon)

## License

Arc Core is licensed under AGPL-3.0.
