# Opteryx

Opteryx is an in-process SQL query engine written in Python/Cython that leverages Apache Arrow as its in-memory format. Designed for ad hoc queries, Opteryx directly queries data from storage without requiring any preloading or preprocessing.

For more information, visit:

- [Opteryx Documentation](https://opteryx.dev/)
- [Opteryx GitHub Repository](https://github.com/mabel-dev/opteryx)

This page provides instructions for benchmarking Opteryx using the split Parquet files provided by ClickBench.

---

## Generating Benchmark Results

To generate benchmark results, follow these steps:

### **High-level Steps**
1. Set up the environment.
2. Install Python and the required dependencies.
3. Download the benchmark dataset.
4. Run the benchmark script.

### **Detailed Instructions**

1. **Start an AWS EC2 instance**
   - OS: Ubuntu 24
   - Architecture: 64-bit
   - Instance Type: `c6a.4xlarge`
   - Root Storage: 500 GB gp2 SSD
   - Advanced Details: Ensure 'EBS-optimized instance' is **disabled**.

2. **SSH into the instance** (after the status checks are complete):
   ~~~bash
   ssh ec2-user@{ip}
   ~~~

3. **Update the package list and install Git**
   ~~~bash
   sudo apt-get update -y
   sudo apt-get install git -y
   ~~~

4. **Clone the ClickBench repository**
   ~~~bash
   git clone https://github.com/ClickHouse/ClickBench
   cd ClickBench/opteryx
   ~~~

5. **Run the benchmark script**
   ~~~bash
   sudo ./benchmark.sh
   ~~~

### Known Issues

- Queries 33 and 34 fail due to Out of Memory (OOM) errors.
