## Setup

1. Create a Databricks workspace and SQL Warehouse (you can do this in the Datbricks UI). Once the SQL Warehouse has been created, copy the warehouse path to use in the .env file
2. Generate a personal access token from your Databricks workspace
3. Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
# Edit .env with your actual credentials
```

## Running the Benchmark

```bash
./benchmark.sh
```

## How It Works

1. **benchmark.sh**: Entry point that installs dependencies via `uv` and runs the benchmark
2. **benchmark.py**: Orchestrates the full benchmark:
   - Creates the catalog and schema
   - Creates the `hits` table with explicit schema (including TIMESTAMP conversion)
   - Loads data from the parquet file using `INSERT INTO` with type conversions
   - Runs all queries via `run.sh`
   - Collects timing metrics from Databricks REST API
   - Outputs results to JSON in the `results/` directory
3. **run.sh**: Iterates through queries.sql and executes each query
4. **query.py**: Executes individual queries and retrieves execution times from Databricks REST API (`/api/2.0/sql/history/queries/{query_id}`)
5. **queries.sql**: Contains the 43 benchmark queries

## Notes

- Query execution times are pulled from the Databricks REST API, which provides server-side metrics
- The data is loaded from a parquet file with explicit type conversions (Unix timestamps → TIMESTAMP, Unix dates → DATE)
- The benchmark uses Databricks SQL Connector for Python
- Results include load time, data size, and individual query execution times (3 runs per query)
- Results are saved to `results/{instance_type}.json`
