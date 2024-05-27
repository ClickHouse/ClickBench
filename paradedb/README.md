# ParadeDB

ParadeDB is an Elasticsearch alternative built on Postgres.

- [GitHub](https://github.com/paradedb/paradedb)
- [Homepage](https://paradedb.com)

The published benchmarks are based on ParadeDB version `v0.7.2`.

## Benchmarks

To run the benchmarks yourself:

1. Manually start an AWS EC2 instance
   - `c6a.4xlarge`
   - Ubuntu Server 22.04 LTS (HVM), SSD Volume Type\*
   - Root 500GB gp2 SSD\*\*
2. Wait for the status check to pass, then SSH into the instance via EC2 Instance Connect
3. Clone this repository via `git clone https://github.com/ClickHouse/ClickBench`
4. Navigate to the `paradedb` directory via `cd ClickBench/paradedb`
5. Run the benchmark via `./benchmark.sh`. This will run the benchmarks against the default settings below.

The benchmark script takes the following parameters:

- `-l`: Location of the dataset, either `local` or `s3`. The default is `local`, meaning the dataset is downloaded on the instance. If you pass in `s3`, the queries will be run directly against a copy of the ClickBench dataset stored in a ParadeDB-hosted AWS S3 bucket in `us-east-1`. For the lowest latency, you should run the benchmark in the same region.
- `-w`: Type of workload, either `single` or `partitioned`. The default is `single`, meaning it uses the single Parquet file `hits.parquet` ClickBench dataset. If you pass in `partitioned`, it uses the one-hundred partitioned Parquet files version of the ClickBench dataset.

\*You can also use Ubuntu 24.04
\*\*You can also use a gp3 volume

The benchmark should be completed within a few minutes. If you'd like to benchmark against a different version of ParadeDB, modify the Docker tag in the `benchmark.sh` script. You can find the list of available tags [here](https://hub.docker.com/r/paradedb/paradedb/tags).
