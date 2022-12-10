# Hydra

Hydra is an open source data warehouse built on Postgres.

* [Homepage](https://hydras.io)
* [GitHub](https://github.com/HydrasDB/hydra)

## Running the benchmark

The benchmark has been configured for a `c6a.4xlarge` running Ubuntu 22.04 and can be run without attendance.

```
export HOST=ec2-127-0-0-1.compute-1.amazonaws.com
scp -i ~/.ssh/aws.pem *.sh *.sql ubuntu@$HOST:~
ssh -i ~/.ssh/aws.pem ubuntu@$HOST ./benchmark.sh
```
