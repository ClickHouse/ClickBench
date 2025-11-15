## Setup

1. Create a Databricks workspace and SQL Warehouse
2. Generate a personal access token from your Databricks workspace
3. Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
# Edit .env with your actual credentials
```

Required environment variables:
- `DATABRICKS_SERVER_HOSTNAME`: Your workspace hostname (e.g., `dbc-xxxxxxxx-xxxx.cloud.databricks.com`)
- `DATABRICKS_HTTP_PATH`: SQL Warehouse path (e.g., `/sql/1.0/warehouses/your-warehouse-id`)
- `DATABRICKS_TOKEN`: Your personal access token
- `databricks_instance_type`: Instance type name for results file naming, e.g., "2X-Large"
- `DATABRICKS_CATALOG`: Unity Catalog name
- `DATABRICKS_SCHEMA`: Schema name
- `DATABRICKS_PARQUET_LOCATION`: S3 path to the parquet file

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
