# Sirius

[Sirius](https://github.com/sirius-db/sirius) is an open-source, GPU-native SQL engine that provides drop-in acceleration for existing databases such as DuckDB.

## Running the benchmark

The benchmark script has been validated on both Lambda Cloud `GH200` instances and AWS EC2 `p5.4xlarge` instances.

### AWS EC2

To run the benchmark on AWS, launch an EC2 instance using the `Deep Learning Base AMI with Single CUDA (Ubuntu 22.04)` (x86 version), which includes CUDA preinstalled.

### Lambda Cloud

Running the benchmark on Lambda Cloud requires no additional setup.