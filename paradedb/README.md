# ParadeDB

TODO: Edit this
ParadeDB is an alternative to Elasticsearch built on Postgres.

- [GitHub](https://github.com/paradedb/paradedb)
- [Homepage](https://paradedb.com)

The published benchmarks are based on ParadeDB version `v0.5.4`.

## Benchmarks

To run the benchmarks yourself:

1. Manually start an AWS EC2 instance
   - `c6a.4xlarge`
   - Ubuntu Server 22.04 LTS (HVM), SSD Volume Type
   - Root 500GB gp2 SSD
2. Wait for the status check to pass, then SSH into the instance via EC2 Instance Connect
3. Clone this repository via `git clone https://github.com/ClickHouse/ClickBench`
4. Navigate to the `paradedb` directory via `cd ClickBench/paradedb`
5. Run the benchmark via `./benchmark.sh`

The benchmark should be completed in under an hour. If you'd like to benchmark against a different version of ParadeDB, modify the Docker tag in `benchmark.sh`. You can find the list of available tags [here](https://hub.docker.com/r/paradedb/paradedb/tags).
