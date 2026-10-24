# Polars Benchmark for ClickBench

This directory contains the script to run the ClickBench benchmark using the Polars streaming engine.

## Prerequisites

The benchmark is containerized using Docker. All dependencies, including Polars, are automatically installed inside the container.

## How to Run

1. Build the Docker image:
   ```bash
   docker build -t clickbench-polars .
   ```

2. Run the benchmark:
   ```bash
   docker run --rm -v \$(pwd):/workspace clickbench-polars
   ```
