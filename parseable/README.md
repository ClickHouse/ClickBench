# Parseable Benchmark

## Overview

Parseable is a **fast observability platform on S3**, built for high-performance log ingestion, querying, and analytics. By benchmarking Parseable against ClickBench, we showcase its ability to efficiently process structured and semi-structured data.

This benchmark utilizes Parquet files with an external table configuration to execute a series of analytical queries.

## Benchmark Setup and Execution

### Prerequisites
- AWS EC2 instance (recommended: `c6a.4xlarge`)
- Amazon Linux 2 AMI
- 500GB gp2 SSD root volume
- SSH access to the EC2 instance

### Installation Steps

1. Launch an AWS EC2 instance with the specification provided above.

2. Connect to the EC2 instance:
   ```
   ssh ec2-user@<instance-ip>
   ```

3. Update system packages and install required dependencies:
   ```
    sudo apt-get update -y
    sudo apt-get install -y gcc git curl build-essential pkg-config libssl-dev
   ```

4. Clone the ClickBench repository:
   ```
   git clone https://github.com/ClickHouse/ClickBench
   cd ClickBench/parseable
   ```

5. Start the Parseable benchmark environment:
   ```
   bash benchmark.sh
   ```

### Data Ingestion

Once Parseable is started, `ingestion.sh` is triggered which starts the ingestion process that performs the following tasks:
   - Downloads and extracts `hits.json.gz`
   - Splits the large JSON file into smaller files (2,500 lines each)
   - Converts each file to proper JSON array format
   - Creates a static schema in Parseable
   - Ingests data in parallel (8 files simultaneously)


### Running Benchmark Queries

Once data ingestion is complete, the benchmark queries are execute using `run_query.sh`
This script will run a series of analytical queries against the ingested dataset and report performance metrics.