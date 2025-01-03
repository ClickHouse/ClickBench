# Opteryx

Opteryx is an in-process query engine written in Python/Cython, that uses Apache Arrow as its in-memory format. For more information, please check <https://opteryx.dev/>

We use the split parquet files for benchmarking and collect them into a folder. Opteryx is an ad hoc engine so there is no loading or preprocessing of the files before querying.

## Generate benchmark results

The steps are broadly to:
- create the environment
- install python
- download the benchmark
- run the benchmark

1. manually start a AWS EC2 instance
    - Ubuntu 24
    - 64-bit Architecture
    - `c6a.4xlarge`
    - Root Storage: 500GB gp2 SSD
    - Advanced: EBS-optimized, disabled
1. wait for status check passed, then ssh to EC2 `ssh ec2-user@{ip}`
1. `sudo apt-get update -y`
1. `sudo apt-get install git -y`
1. `git clone https://github.com/mabel-dev/ClickBench`
1. `cd ClickBench/opteryx`
1. `sudo ./benchmark_latest.sh`

### Know Issues:

1. Not all functions used in queries are supported
