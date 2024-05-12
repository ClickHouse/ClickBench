# Opteryx

Opteryx is an in-process query engine written in Python/Cython, that uses Apache Arrow as its in-memory format. For more information, please check <https://opteryx.dev/latest>

We use the split parquet files here collected into a folder; and then do the queries. Opteryx is an ad hoc engine so there is no loading or preprocessing of the files before querying.

## Generate benchmark results

The benchmark should be completed in under an hour. On-demand pricing is $0.6 per hour while spot pricing is only $0.2 to $0.3 per hour (us-east-2).

1. manually start a AWS EC2 instance
    - `c6a.4xlarge`
    - Amazon Linux 2 AMI
    - Root 500GB gp2 SSD
    - no EBS optimized
    - no instance store
1. wait for status check passed, then ssh to EC2 `ssh ec2-user@{ip}`
1. `sudo yum update -y` and `sudo yum install gcc git -y`
1. `git clone https://github.com/ClickHouse/ClickBench`
1. `cd ClickBench/opteryx`
1. `bash benchmark.sh`

### Know Issues:

1. Not all queries are currently supported
