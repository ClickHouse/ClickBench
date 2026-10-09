# ClickHouse Hardware Benchmark

This is a benchmark for hardware based on ClickBench.
You can run a basic performance test on any server, VM, desktop, laptop, edge device or appliance, without installation of ClickHouse packages.

Run as
```
curl https://raw.githubusercontent.com/ClickHouse/ClickBench/main/hardware/hardware.sh | bash
```

In case of any complications, you can download the script above and edit it accordingly.

A version of this benchmark is also used by Phoronix.

## Automated runs on AWS

The "Run the hardware benchmark" GitHub workflow (`.github/workflows/hardware-benchmark.yml`) launches one self-terminating EC2 machine per instance type with `run-benchmark.sh`.
The machine assembles its local SSDs (instance store), if it has any, into a RAID 0 array, formats and mounts it, and runs `hardware.sh` there; otherwise the data stays on the root EBS volume (gp3, 16000 IOPS, 1000 MB/s).
The result is sent to the sink at play.clickhouse.com and collected hourly by `collect-new-results.sh` into `results/aws_<instance type>.json`.

```
./run-benchmark.sh m7i.48xlarge
./list-machines.sh general-purpose | xargs -n1 ./run-benchmark.sh
```
